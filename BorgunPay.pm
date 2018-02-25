package Koha::Plugin::Com::RBitTechnology::BorgunPay;

use Modern::Perl;
use base qw(Koha::Plugins::Base);
use utf8;
use C4::Context;
use Koha::Account::Lines;
use LWP::UserAgent;
use HTTP::Headers;
use HTTP::Request::Common;
use JSON;
use HTML::Entities;
use Digest::SHA qw/hmac_sha256_hex hmac_sha256/;

our $VERSION = "1.0.0";

our $metadata = {
    name            => 'Platební brána Borgun',
    author          => 'Radek Šiman',
    description     => 'Toto rozšíření poskytuje podporu online plateb s využitím brány Borgun.',
    date_authored   => '2018-02-25',
    date_updated    => '2018-02-25',
    minimum_version => '16.05',
    maximum_version => undef,
    version         => $VERSION
};

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);
    $self->{'ua'} = LWP::UserAgent->new();

    return $self;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({ file => 'configure.tt' });
    my $phase = $cgi->param('phase');

    my $table_clients = $self->get_qualified_table_name('clients');
    my $dbh = C4::Context->dbh;

    unless ( $phase ) {
        my $query = "SELECT client_id, borrowernumber, firstname, surname, userid, secret FROM $table_clients INNER JOIN borrowers USING(borrowernumber) ORDER BY surname, firstname";
        my $sth = $dbh->prepare($query);
        $sth->execute();

        my @clients;
        while ( my $row = $sth->fetchrow_hashref() ) {
            push( @clients, $row );
        }

        print $cgi->header(-type => 'text/html',
                           -charset => 'utf-8');
        $template->param(
            merchantid => $self->retrieve_data('merchantid'),
            paymentgatewayid => $self->retrieve_data('paymentgatewayid'),
            secretkey => $self->retrieve_data('secretkey'),
            borgun_server => $self->retrieve_data('borgun_server'),
            api_clients => \@clients
        );
        print $template->output();
        return;
    }
    elsif ( $phase eq 'save_borgun' ) {
        $self->store_data(
            {
                merchantid => scalar $cgi->param('merchantid'),
                paymentgatewayid => scalar $cgi->param('paymentgatewayid'),
                secretkey => scalar $cgi->param('secretkey'),
                borgun_server => scalar $cgi->param('borgun_server'),
                last_configured_by => C4::Context->userenv->{'number'},
            }
        );
    }
    elsif ( $phase eq 'save_clients' ) {
        my $borrowernumber = $cgi->param('borrowernumber');
        my $secret = $cgi->param('secret');

        if ( $borrowernumber && $secret ) {
            my $query = "INSERT INTO $table_clients (secret, borrowernumber) VALUES (?, ?);";
            my $sth = $dbh->prepare($query);
            $sth->execute($secret, $borrowernumber);
        }
    }
    elsif ( $phase eq 'delete' ) {
        my $client_id = $cgi->param('client_id');

        if ( $client_id ) {
            my $query = "DELETE FROM $table_clients WHERE client_id = ?;";
            my $sth = $dbh->prepare($query);
            $sth->execute($client_id);
        }

        my $staffClientUrl =  C4::Context->preference('staffClientBaseURL');
        print $cgi->redirect(-uri => "$staffClientUrl/cgi-bin/koha/plugins/run.pl?class=Koha::Plugin::Com::RBitTechnology::BorgunPay&method=configure");
    }

    $self->go_home;
}

sub check_params {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $patron = $cgi->param('patron');
    my $return_url = $cgi->param('return_url');
    my $hmac_post = $cgi->param('hmac');

    unless ($patron && $return_url && $hmac_post) {
        $self->error({ errors => [ { message => 'Chybí jeden nebo více povinných parametrů.' } ], return_url => $return_url ? $return_url : 0 });
        return 0;
    }

    my $userid = $cgi->param('userid');
    my $password = $cgi->param('password');
    my $borrowernumber = C4::Context->userenv->{'number'};

    my $dbh = C4::Context->dbh;
    my $table_clients = $self->get_qualified_table_name('clients');
    my $query = "SELECT secret FROM $table_clients WHERE borrowernumber = ?";
    my $sth = $dbh->prepare($query);
    $sth->execute($borrowernumber);
    unless ( $sth->rows ) {
        $self->error({ errors => [ { message => "Pro přihlašovací jméno $userid neexistuje klientský záznam." } ], return_url => $return_url });
        return 0;
    }

    my $row = $sth->fetchrow_hashref();
    my $hmac = hmac_sha256_hex("$userid|$password|$patron|$return_url", $row->{'secret'});

    unless ( $hmac eq $hmac_post ) {
        $self->error({ errors => [ { message => "Neoprávněný požadavek, nepodařilo se ověřit HMAC." } ], return_url => $return_url });
        return 0;
    }

    unless ( $self->retrieve_data('secretkey') && $self->retrieve_data('merchantid') && $self->retrieve_data('paymentgatewayid') ) {
        $self->error({ errors => [ { message => "Chybí nastavení parametrů platební brány SecretKey, MerchantID, PaymentGatewayID). Dokončete prosím konfiguraci platební brány." } ], return_url => $return_url });
        return 0;
    }

    return 1;
}

sub opac_online_payment {
    my ( $self, $args ) = @_;

    return 1;
}

sub opac_online_payment_begin {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    return unless ( $self->check_params );
    my $return_url = $cgi->param('return_url');

    my $staffClientUrl =  "http://mbp.home.local:8081";  #C4::Context->preference('staffClientBaseURL');

    my $table_trans = $self->get_qualified_table_name('transactions');
    my $table_items = $self->get_qualified_table_name('items');
    my $dbh = C4::Context->dbh;

    my $member = Koha::Patrons->find( { borrowernumber => scalar $cgi->param('patron') } );
    my @outstanding_fines;
    @outstanding_fines = Koha::Account::Lines->search(
        {
            borrowernumber    => scalar $cgi->param('patron'),
            amountoutstanding => { '>' => 0 },
        }
    );
    my $amount_to_pay = 0;
    my @items;
    foreach my $fine (@outstanding_fines) {
        $amount_to_pay += int(100 * $fine->amountoutstanding) / 100;
        push( @items, { name => $fine->description ? $fine->description : "Platba bez popisu", amount => int(100 * $fine->amountoutstanding) / 100 } );
    }

    unless ( scalar @items ) {
        $self->error({ errors => [ { message => 'Nebyly nalezeny žádné položky k úhradě.' } ], return_url => $return_url });
        return;
    }

    $dbh->do("START TRANSACTION");

    my $query = "INSERT INTO $table_trans (paid, return_url) VALUES (NULL, ?)";
    my $sth = $dbh->prepare($query);
    $sth->execute($return_url);
    my $transaction_id = $dbh->last_insert_id(undef, undef, $table_trans, 'transaction_id');

    my $returnUrlSuccess = "$staffClientUrl/cgi-bin/koha/svc/pay_api?phase=return&amp;action=success";

    my @hmac_fields = (
        $self->retrieve_data('merchantid'),
        $returnUrlSuccess,
        $returnUrlSuccess,
        $transaction_id,
        $amount_to_pay,
        'CZK'
    );

    my $params = {
        'merchantid' => $self->retrieve_data('merchantid'),
        'paymentgatewayid' => $self->retrieve_data('paymentgatewayid'),
        'checkhash' => hmac_sha256_hex(join('|', @hmac_fields), $self->retrieve_data('secretkey')),
        'orderid' => $transaction_id,
        'amount' => $amount_to_pay,
        'currency' => 'CZK',
        'language' => 'CZ',
        'buyername' => $member->firstname . ' ' . $member->surname,
        'buyeremail' => $member->email,
        'returnurlsuccess' => $returnUrlSuccess,
        'returnurlsuccessserver' => $returnUrlSuccess,
        'returnurlerror' => "$staffClientUrl/cgi-bin/koha/svc/pay_api?phase=return&amp;action=error",
    };

    for my $i (0 .. $#items) {
        my $fine = $items[$i];
        $params->{"Itemdescription_$i"} = $fine->{name};
        $params->{"Itemcount_$i"} = 1;
        $params->{"Itemunitamount_$i"} = $fine->{amount};
        $params->{"Itemamount_$i"} = $params->{"Itemcount_$i"} * $params->{"Itemunitamount_$i"};
    }

    my $ua = LWP::UserAgent->new();
    my $request = POST $self->api, $params;
    $request->header('Content-Type' => 'application/x-www-form-urlencoded');
    my $response = $ua->request($request);

    if (!$response->is_success) {
        $self->error({ errors => [ { message => 'Nelze se připojit k platebnímu serveru.'} ], return_url => $return_url });
        return;
    }

    my @values;
    my @bindParams;

    $query = "INSERT INTO $table_items (accountlines_id, transaction_id) VALUES ";
    foreach my $fine (@outstanding_fines) {
        push( @values, "(?, ?)" );
        push( @bindParams, $fine->accountlines_id );
        push( @bindParams, $transaction_id );
    }
    $query .= join(', ', @values);
    $sth = $dbh->prepare($query);

    for my $i (0 .. $#bindParams) {
        $sth->bind_param($i + 1, $bindParams[$i]);
    }

    $sth->execute();

    my %args = split /[&=]/, $response->content;
    if ($args{ret} eq 'True') {
        $query = "UPDATE $table_trans SET ticket=? WHERE transaction_id=?; ";
        $sth = $dbh->prepare($query);
        $sth->execute($args{ticket}, $transaction_id);

        $dbh->do("COMMIT");

        print $cgi->redirect($self->api . "?ticket=" . $args{ticket});
        return;
    }

    $dbh->do("COMMIT");

    $self->error({ errors => [ { message => 'Nelze provést platbu (' . $args{message} . ').' } ], return_url => $return_url });
}

sub opac_online_payment_end {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $dbh = C4::Context->dbh;
    my $table_items = $self->get_qualified_table_name('items');
    my $table_trans = $self->get_qualified_table_name('transactions');

    my $ticket = scalar $cgi->param('ticket');
    my $query = "SELECT transaction_id, return_url FROM $table_trans WHERE ticket = ?";
    my $sth = $dbh->prepare($query);
    $sth->execute( $ticket );
    unless ( $sth->rows ) {
        $self->error({ errors => [ { message => 'Platba s touto identifikací neexistuje nebo již byla uhrazena dříve.' } ] });
        return;
    }

    my $row = $sth->fetchrow_hashref();
    my $return_url = $row->{'return_url'};
    my $transation_id = $row->{'transaction_id'};
    my $status = scalar $cgi->param('status');

    my @hmac_fields = (
        $cgi->param('orderid'),
        $cgi->param('amount'),
        $cgi->param('currency')
    );
    my $orderhash = hmac_sha256_hex(join('|', @hmac_fields), $self->retrieve_data('secretkey'));

    if ($orderhash ne $cgi->param('orderhash')) {
        $self->error({ errors => [ { message => 'Byl použit neplatný validační kód. Platba zůstane neuhrazena.' } ], return_url => $return_url });
        return;
    }

    if ( $status eq 'OK' ) {
        $dbh->do("START TRANSACTION");


        $query = "SELECT accountlines_id, borrowernumber, amountoutstanding FROM $table_items "
                ." INNER JOIN $table_trans USING(transaction_id)"
                ." INNER JOIN accountlines USING(accountlines_id)"
                ." WHERE transaction_id = ? AND paid IS NULL";
        $sth = $dbh->prepare($query);
        $sth->execute( $transation_id );

        my $note = "Borgun " . $ticket;
        while ( my $row = $sth->fetchrow_hashref() ) {
            my $account = Koha::Account->new( { patron_id => $row->{'borrowernumber'} } );
            $account->pay(
                {
                    amount     => $row->{'amountoutstanding'},
                    lines      => [ scalar Koha::Account::Lines->find($row->{'accountlines_id'}) ],
                    note       => $note,
                }
            );
        }

        $query = "UPDATE $table_trans SET paid = NOW() WHERE transaction_id = ?";
        $sth = $dbh->prepare($query);
        $sth->execute( $transation_id );

        $dbh->do("COMMIT");

        $self->message({ text => 'Platba byla přijata. Děkujeme za úhradu.', return_url => $return_url });
    }
    else {
        $self->error({ errors => [ { message => 'Platba nebyla uhrazena.' } ], return_url => $return_url });
        return
    }

}

sub install {
    my ( $self, $args ) = @_;

    my $table_items = $self->get_qualified_table_name('items');
    my $table_trans = $self->get_qualified_table_name('transactions');
    my $table_clients = $self->get_qualified_table_name('clients');

    return C4::Context->dbh->do( "
        CREATE TABLE `$table_trans` (
            `transaction_id` int NOT NULL AUTO_INCREMENT,
            `ticket` varchar(20) DEFAULT NULL,
            `created` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `paid` timestamp NULL DEFAULT NULL,
            `return_url` varchar(128) NOT NULL,
            PRIMARY KEY (`transaction_id`)
        ) ENGINE = INNODB DEFAULT CHARACTER SET = utf8 COLLATE = utf8_czech_ci;
        " ) &&
        C4::Context->dbh->do( "
        CREATE TABLE `$table_items` (
            `accountlines_id` int NOT NULL,
            `transaction_id` int NOT NULL,
            PRIMARY KEY (`accountlines_id`, `transaction_id`),
            CONSTRAINT `FK_borgunpay_accountlines` FOREIGN KEY (`accountlines_id`) REFERENCES `accountlines` (`accountlines_id`) ON UPDATE CASCADE ON DELETE CASCADE,
            CONSTRAINT `FK_borgunpay_transactions` FOREIGN KEY (`transaction_id`) REFERENCES `$table_trans` (`transaction_id`) ON UPDATE CASCADE ON DELETE CASCADE,
            INDEX (`accountlines_id`),
            INDEX (`transaction_id`)
        ) ENGINE = INNODB DEFAULT CHARACTER SET = utf8 COLLATE = utf8_czech_ci;" ) &&
        C4::Context->dbh->do( "
        CREATE TABLE `$table_clients` (
            `client_id` int NOT NULL AUTO_INCREMENT,
            `secret` varchar(64) NOT NULL,
            `borrowernumber` int NOT NULL,
            PRIMARY KEY (`client_id`),
            INDEX (`borrowernumber`),
            CONSTRAINT `FK_borgunpay_client_borrowers` FOREIGN KEY (`borrowernumber`) REFERENCES `borrowers` (`borrowernumber`) ON UPDATE CASCADE ON DELETE CASCADE
        ) ENGINE = INNODB DEFAULT CHARACTER SET = utf8 COLLATE = utf8_czech_ci;
        ");
}

sub uninstall {
    my ( $self, $args ) = @_;

    my $table_items = $self->get_qualified_table_name('items');
    my $table_trans = $self->get_qualified_table_name('transactions');
    my $table_clients = $self->get_qualified_table_name('clients');

    return C4::Context->dbh->do("DROP TABLE `$table_items`") &&
           C4::Context->dbh->do("DROP TABLE `$table_trans`") &&
           C4::Context->dbh->do("DROP TABLE `$table_clients`");
}

sub error {
    my ( $self, $args ) = @_;

    my $template = $self->get_template({ file => 'dialog.tt' });
    $template->param(
        error => 1,
        report => $args->{'errors'},
        return_url => $args->{'return_url'}
    );
    print $template->output();
}

sub message {
    my ( $self, $args ) = @_;

    my $template = $self->get_template({ file => 'dialog.tt' });
    $template->param(
        error => 0,
        report => $args->{'text'},
        return_url => $args->{'return_url'}
    );
    print $template->output();
}

sub api {
    my ( $self, $args ) = @_;
    return $self->retrieve_data('borgun_server') eq 'production' ? 'https://securepay.borgun.is/securepay/ticket.aspx': 'https://test.borgun.is/securepay/ticket.aspx';
}
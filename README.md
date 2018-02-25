![logo KohaCZ](https://github.com/open-source-knihovna/SmartWithdrawals/blob/master/SmartWithdrawals/koha_cz.png "Logo Česká komunita Koha")
![logo R-Bit Technology, s.r.o.](https://github.com/open-source-knihovna/SmartWithdrawals/blob/master/SmartWithdrawals/logo.png "Logo R-Bit Technology, s.r.o.")

Zásuvný modul vytvořila společnost R-Bit Technology, s. r. o. ve spolupráci s českou komunitou Koha.

# Úvod

Zásuvný modul 'BorgunPay' implementuje možnost platit uživatelům knihovny poplatky on-line přes platební bránu Borgun. Platba může být iniciována jak z OPACu Kohy, tak i z téměř libovolného jiné systému (VuFind, Centrální portál knihoven atp.). Pokud je platba úspěšná, dojde k okamžité úhradě všech dlužných poplatků v systému. Součástí modulu je jednoduchá konfigurace, kde se vyplňují identifikační údaje pro bránu.

# Instalace

## Zprovoznění Zásuvných modulů

Institut zásuvných modulů umožňuje rozšiřovat vlastnosti knihovního systému Koha dle specifických požadavků konkrétní knihovny. Zásuvný modul se instaluje prostřednictvím balíčku KPZ (Koha Plugin Zip), který obsahuje všechny potřebné soubory pro správné fungování modulu.

Pro využití zásuvných modulů je nutné, aby správce systému tuto možnost povolil v nastavení.

Nejprve je zapotřebí provést několik změn ve vaší instalaci Kohy:

* V souboru koha-conf.xml změňte `<enable_plugins>0</enable_plugins>` na `<enable_plugins>1</enable_plugins>`
* Ověřte, že cesta k souborům ve složce `<pluginsdir>` existuje, je správná a že do této složky může webserver zapisovat
* Pokud je hodnota `<pluginsdir>` např. `/var/lib/koha/kohadev/plugins`, vložte následující kód do konfigurace webserveru:
```
Alias /plugin/ "/var/lib/koha/kohadev/plugins/"
<Directory "/var/lib/koha/kohadev/plugins">
  Options +Indexes +FollowSymLinks
  AllowOverride All
  Require all granted
</Directory>
```
* Načtěte aktuální konfiguraci webserveru příkazem `sudo service apache2 reload`

Jakmile je nastavení připraveno, budete potřebovat změnit systémovou konfigurační hodnotu UseKohaPlugins v administraci Kohy. Aktuální verzi modulu [stahujte v sekci Releases](https://github.com/open-source-knihovna/BorgunPay/releases).

## Nastavení specifické pro modul



Více informací, jak s nástrojem pracovat naleznete na [wiki](https://github.com/open-source-knihovna/BorgunPay/wiki)

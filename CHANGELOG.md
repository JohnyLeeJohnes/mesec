# Changelog

Všechny podstatné změny v projektu. Formát vychází z [Keep a Changelog](https://keepachangelog.com/cs/1.1.0/),
verze se řídí [sémantickým verzováním](https://semver.org/lang/cs/).

## [1.0.2] - 2026-10-06

### Změněno

- `install.cmd` po sobě odblokuje soubory Měšce. Kdo ZIP před rozbalením neodblokoval, má po instalaci
  soubory bez značky „z internetu“ a Windows se u nich přestane ptát.

## [1.0.1] - 2026-10-06

Aplikace je stejná jako 1.0.0, mění se způsob, jak se k ní dostat.

### Přidáno

- ZIP ke stažení u vydání. Odkaz
  [Mesec.zip](https://github.com/JohnyLeeJohnes/mesec/releases/latest/download/Mesec.zip) vede vždycky
  na nejnovější verzi: stáhnout, odblokovat, rozbalit a poklepat na `install.cmd`.
- `tools/make-release.ps1`, který ZIP sestaví do `dist/`. Je v něm jen to, co Měšec potřebuje k běhu;
  testy, nástroje a obrázky do README zůstávají v repozitáři.

### Změněno

- Instalace v README vede přes ZIP. `git clone` zůstává jako druhá možnost.

## [1.0.0] - 2026-10-06

První vydání.

### Přidáno

- Zámek se čtyřmístným PINem: při prvním spuštění si ho zvolíš, příště jen napíšeš. Čtvrtá číslice odesílá
  sama a číslice z horní řady fungují i bez Shiftu.
- Platby s názvem, částkou, dnem splatnosti, příjemcem a typem (bydlení, energie, zdravotní a sociální
  pojištění, daně, penzijní spoření, investice, spoření, splátky, předplatné a další). Opakované každý
  měsíc, nebo jednorázové; příjem je položka s typem Příjem.
- Odškrtávání zaplacených plateb zvlášť pro každý měsíc a zvýraznění těch, které jsou po splatnosti.
- Změna nebo smazání opakované platby platí od zobrazeného měsíce dál, starší měsíce zůstávají, jak byly.
- Přehled měsíce: příjmy, výdaje, kolik zbývá a kolik je ještě potřeba zaplatit.
- Grafy: výdaje podle typu a výdaje po měsících celého roku s průměrem. Kliknutím na sloupec se přejde
  na ten měsíc.
- Šifrování dat PINem: AES-256 s kontrolním součtem HMAC-SHA256, klíč odvozený přes PBKDF2 (200 000 kol).
  Soubor `%APPDATA%\Mesec\data.bin` je navíc zabalený do DPAPI, které ho váže na účet Windows.
- Záloha do souboru `.mesec` a obnova ze zálohy na úvodní obrazovce.
- Změna PINu a zamknutí bez zavření aplikace.
- Ukázkový režim `-Demo` bez PINu, který na disk nic neukládá.
- Tmavý vzhled včetně titulkového pruhu okna, ikona ve velikostech 16 až 256 px a `install.cmd`, který
  vytvoří zástupce v nabídce Start, na ploše a ve složce s aplikací.
- Měšec je skript v PowerShellu s oknem ve WPF, takže se nic nekompiluje ani neinstaluje a nevadí mu
  Smart App Control.
- Test `tests/test.ps1`, který zkouší šifrování, počítání po měsících a projde okno.

[1.0.2]: https://github.com/JohnyLeeJohnes/mesec/releases/tag/v1.0.2
[1.0.1]: https://github.com/JohnyLeeJohnes/mesec/releases/tag/v1.0.1
[1.0.0]: https://github.com/JohnyLeeJohnes/mesec/releases/tag/v1.0.0

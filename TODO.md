# Mailmule – TODO

Cieľ: prekonať Mail.app pri každodennom používaní (viac účtov, Markdown, klávesnica, Obsidian).

## Rozpracované

- [ ] **Okamžitá pošta a notifikácie**
  - [ ] IMAP IDLE na INBOX každého účtu (samostatné spojenie, obnova pri výpadku/spánku)
  - [ ] Systémové notifikácie o novej pošte (odosielateľ, predmet; klik otvorí vlákno)
  - [ ] Počet neprečítaných na ikone v Docku

## Ďalej – nové Nastavenia (podľa grafických návrhov)

Zásada: v nastaveniach nie sú prepínače, ktoré nič nerobia.

- [x] **1. Kostra:** bočný panel s 9 kategóriami, hlavička stránky s ikonou, karty, presun existujúcich volieb
- [x] **2. Účty:** zoznam so stavom synchronizácie, vypnutie účtu, primárny účet / predvolený odosielateľ,
      frekvencia synchronizácie (okamžite/1/5/15 min), návrhy adries z Kontaktov
- [x] **2. Písanie:** formátovacie tlačidlá podpisu, čistý/formátovaný text, veľkosť písma editora,
      jazyk pravopisu, kde vkladať podpis
- [x] **2. Vzhľad:** motív, kompaktný zoznam, ukážka správy, veľké avatary, 2/3 stĺpce, intenzita prekrytia,
      kontrast textu, riadkovanie, dĺžka ukážky, živý náhľad
- [x] **2. Oznámenia:** bannery, zvuk, Dock, ukážka textu, len VIP, VIP odosielatelia, tichý režim, podľa účtu
- [x] **2. Súkromie:** pixely, obrázky, výnimky aj pre domény, varovanie pri podozrivom odosielateľovi
- [x] **2. Úložisko:** využitie (správy/index/koncepty), priečinok na prílohy, Obsidian, údržba
- [x] **2. Klávesové skratky:** prehľad skutočných skratiek
- [x] **2. Rozšírené:** logy, diagnostika, export/import nastavení, záloha, obnova predvolených, odhlásenie účtov
- [x] **3. Pravidlá a automatizácie** (podmienka → akcia, šablóny) – samostatná etapa
- [ ] **4.** úprava vlastných skratiek, aliasy odosielateľa, hľadanie v nastaveniach

- [x] **Podpisy**
  - [x] Podpis pre každý účet v Markdowne (nastavenia)
  - [x] Automatické vloženie do novej správy a odpovede (nad citát)

## Ďalšie vylepšenia (návrhy 14. 10. 2026)

- [x] Sledovanie odpovedí: „pripomeň, ak do N dní neodpovie“ (na základe odloženia, návrat do Doručenej s poznámkou)
- [x] Vyhľadávanie s operátormi: `from:`, `to:`, `has:attachment`, `is:unread`, `is:starred`, `after:`, `before:`
- [x] Odhlásenie z newslettra jedným klikom (List-Unsubscribe / List-Unsubscribe-Post)
- [x] Náhľad príloh cez Quick Look (medzerník) bez ukladania
- [ ] Aliasy odosielateľa (ďalšia adresa cez existujúci účet) – len ak sa budú používať
- [x] Vlastné klávesové skratky
- [x] Asistent s lokálnym modelom (MLX, Qwen3.5 4B): súhrn vlákna, návrh odpovede – pošta neopúšťa Mac
- [ ] Asistent: triedenie Doručenej (dôležité / newsletter / notifikácia)

## Rozpracované (14. 10. 2026)

- [x] Logá firiem a fotky odosielateľov (Kontakty, BIMI, ikona domény) namiesto iniciál
- [x] Tlač a export vlákna do PDF (⌘P)
- [x] Viac okien: vlákno a písanie v samostatnom okne
- [x] Pozvánky do kalendára (.ics): Prijať / Možno / Odmietnuť, odpoveď organizátorovi, zápis do Kalendára

## Rozpracované (15. 10. 2026)

- [x] Mailmule ako predvolená pošta (mailto:) a „Poslať e-mailom“ z Findera (Služby)
- [x] Prehľad všetkých príloh (filter podľa typu, hľadanie, náhľad, uloženie)
- [x] Pohľad na človeka/firmu (vlákna a prílohy s ním, posledný kontakt)
- [x] Hľadanie v Nastaveniach
- [x] Prehľad (domovská stránka ako v Pathfinderi) + napojenie Kalendára z Macu
- [x] STARTTLS pre IMAP (143) aj SMTP (587)
- [x] Uložené hľadania v bočnom paneli
- [x] Odchádzajúca pošta: opakované odoslanie po výpadku siete, zrozumiteľné chyby, indikátor Bez pripojenia
- [x] Poškodená databáza sa vytvorí nanovo; denná kontrola a záloha nastavení
- [x] README, hardened runtime, `scripts/release.sh` (Developer ID, DMG, notarizácia)
- [ ] Certifikát Developer ID + údaje pre notarizáciu (urobí používateľ), potom prvé vydanie
- [ ] Automatické aktualizácie (Sparkle) – potrebuje miesto na zverejnenie (napr. GitHub Releases)

## Neskôr

- [ ] Šablóny odpovedí z Obsidian trezoru
- [ ] Gmail cez OAuth (namiesto hesla aplikácie)
- [x] Vložené obrázky (cid:) v prijatých e-mailoch, „Načítať obrázky“ pre dôveryhodných odosielateľov
- [x] Synchronizácia konceptov so serverom (priečinok Drafts)
- [x] Doplňovanie adries v Komu/Kópia (história pošty + Kontakty macOS)

## Hotové

- [x] Odloženie (`h`): priečinok Odložené na serveri, návrat do Doručenej ako neprečítané + pripomienka
- [x] Naplánované odoslanie: „Odoslať neskôr…“ v editore, priečinok Naplánované (odošle sa, keď beží Mailmule)
- [x] Globálne štítky: bočný panel a počty zo všetkých účtov, štítok ukáže vlákna všetkých účtov,
      „Práca“ = „práca“ (diakritika sa rozlišuje), zápis sa zjednotí s existujúcim štítkom
- [x] Témy ako v Pathfinderi (Nastavenia → Vzhľad): Mailmule, Systém, Glass, 17 palet, režim, farba zvýraznenia,
      hory a heslo v bočnom paneli, obrázok na pozadí
- [x] Redizajn podľa návrhov (tmavý bočný panel, záložky filtrov, panel akcií, rýchla odpoveď s návrhmi)
- [x] Nastavenie sťahovania pre každý účet: limit histórie (300 / 3 mes. / 1 / 2 / 5 rokov / všetko)
      a prílohy vždy alebo až pri otvorení (BODYSTRUCTURE, čiastočné .eml, doplnenie na požiadanie)
- [x] Zobrazenie zoznamu: radenie, zoskupenie, filtre, kompaktné riadky
- [x] Celá história: najnovších 300 správ hneď, staršie na pozadí po dávkach 200 (priebeh v bočnom paneli)
- [x] Vlastné priečinky servera v bočnom paneli (s hierarchiou), presun ťahaním, `v` a cez pravý klik
      (Gmail: priečinky sú štítky)
- [x] Koncepty: automatické ukladanie do `~/Mail/drafts/*.md` (+ prílohy), priečinok Koncepty (⌘⇧D),
      „Zahodiť“ / „Zavrieť“, rozpísaná odpoveď vo vlákne (`r` pokračuje v nej)
- [x] Synchronizácia Gmail + IMAP, mail vault (`.eml` + `.md`), SQLite index s vyhľadávaním
- [x] Viac účtov, spoločná doručená pošta, farby účtov
- [x] Editor so živým Markdownom, prílohy, preposielanie
- [x] Archív, Kôš, vrátenie akcie (5 s)
- [x] Export vlákna do Obsidianu aj s prílohami (`Mail/Prílohy/<poznámka>/`, PDF a obrázky vložené), odkazy `mailmule://`
- [x] Presúvanie ťahaním na Doručenú/Archív/Kôš a cez pravý klik
- [x] Hviezdičky (`s`), prečítané/neprečítané (`u`), štítky (`l`) – Gmail štítky / IMAP kľúčové slová,
      priečinok „S hviezdičkou“, sekcia „Štítky“ v bočnom paneli (aj ťahaním na štítok)
- [x] Štítky ako vo Finderi/Pathfinderi: farby a obľúbené z Findera, bodky v zozname, pilulky s × v hlavičke,
      štítky Findera na poznámkach vlákien a exportoch do Obsidianu (Spotlight ich nájde)

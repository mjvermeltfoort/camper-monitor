# Camper Monitor

Een privé dashboard voor één camper. Het dashboard toont actuele accu-, gas-,
gateway- en locatiegegevens uit Supabase en bewaart onafhankelijke metingen voor
de grafieken en de geschatte GPS-route van 24 uur, 7 dagen en 30 dagen.

## Wat staat er in deze repository?

- `index.html` — het responsieve dashboard met Google-login.
- `manifest.webmanifest` en `assets/icons/` — metadata en iconen voor installatie
  als webapp.
- `config.example.js` — voorbeeld van de publieke browserconfiguratie.
- `supabase/migrations/` — tabellen, checks, indexen, RLS-policies,
  gatewayfuncties en dashboard-RPC's in uitvoervolgorde.
- `supabase/bootstrap.example.sql` — eenmalige koppeling van de kijker en de
  campertelefoon.

De database accepteert bewust maar één rij in `public.camper`. Er is geen
huishouden-, vloot- of camperkeuzemodel.

## 1. Supabase-project instellen

1. Maak een Supabase-project aan.
2. Voer alle bestanden in `supabase/migrations/` op bestandsnaamvolgorde uit
   met de Supabase CLI. Bij handmatige installatie plak je ze in dezelfde
   volgorde in de SQL Editor.
3. Schakel in **Authentication > Providers** de Google-provider in en vul de
   Google OAuth client-ID en client secret in.
4. Voeg in zowel Google Cloud als Supabase de URL van het dashboard toe als
   toegestane redirect-URL. Voeg voor lokaal gebruik bijvoorbeeld
   `http://127.0.0.1:8000/index.html` toe.

De frontend gebruikt alleen de publieke project-URL en publishable key. Zet
nooit een secret key of `service_role`-key in browsercode.

## 2. Kijker en gateway aanmaken

1. Open het dashboard eenmaal en log in met het Google-account dat toegang moet
   krijgen. De eerste poging toont nog "geen toegang" maar maakt de Auth-user
   wel aan.
2. Kopieer de UUID van deze gebruiker uit **Authentication > Users**.
3. Maak in hetzelfde scherm een aparte email/password Auth-user voor de
   campertelefoon. Gebruik deze account nergens als menselijke login.
4. Kopieer `supabase/bootstrap.example.sql`, vervang de twee Auth-UUID's en pas
   campernaam/model aan.
5. Voer het aangepaste bootstrap-script één keer uit in de SQL Editor.

Het vaste device-ID uit het voorbeeld (`00000000-0000-0000-0000-000000000010`)
mag worden gewijzigd, maar moet daarna ook door de gateway worden gebruikt.

## 3. Dashboard configureren en starten

```bash
cp config.example.js config.js
python3 -m http.server 8000
```

Vul in `config.js` de project-URL en publishable key uit **Project Settings >
API** in. `config.js` staat in `.gitignore`. Open daarna:

`http://127.0.0.1:8000/`

De standaardkaart gebruikt de openbare MapLibre-demostijl. Zet voor productie
`mapStyleUrl` op een eigen of geschikt gehost kaartstijl-endpoint met passende
capaciteit en gebruiksvoorwaarden.

## Dashboard als webapp installeren

Open het gepubliceerde dashboard eerst in de browser en log in. In Chromium op
desktop of Android verschijnt `Installeer app` in de hoofdbalk zodra de browser
installatie aanbiedt. Klik daarop en bevestig de native installatieprompt. Je
kunt ook de installatieoptie uit het browsermenu gebruiken.

Open het dashboard op iPhone of iPad in Safari, tik op **Deel** en kies
**Zet op beginscherm**. Safari gebruikt de naam en het Apple-touch-icon van het
dashboard; daar wordt geen aparte installatieknop getoond.

De webapp heeft bewust geen service worker of offline cache. Login,
dashboardgegevens, de kaart, Supabase en wisselkoersen blijven een
internetverbinding vereisen.

## Gateway-authenticatie

De gateway logt in met zijn eigen email/password Auth-user. Bewaar het
wachtwoord en de verkregen refresh token uitsluitend op de gateway.

```bash
curl -sS -X POST \
  "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"email":"gateway@example.invalid","password":"VERVANG_DIT"}'
```

Gebruik de `access_token` als bearer token bij inserts. Maak voor elke fysieke
meting één UUID op de gateway en hergebruik die UUID bij retries. Daardoor maakt
een retry geen dubbele gebeurtenis. Vraag geen ingevoegde rij terug: gateways
hebben uitsluitend insertrechten.

```bash
curl -sS -X POST "$SUPABASE_URL/rest/v1/battery_readings" \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $GATEWAY_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  -d '{
    "id":"11111111-1111-4111-8111-111111111111",
    "device_id":"00000000-0000-0000-0000-000000000010",
    "recorded_at":"2026-08-01T10:00:00Z",
    "soc_pct":91,
    "voltage_v":12.74,
    "current_a":-1.8,
    "power_w":-23
  }'
```

De overige endpoints volgen hetzelfde patroon:

| Tabel | Vereiste meetvelden | Optioneel |
| --- | --- | --- |
| `gas_readings` | `fill_pct`, `mass_kg`, `temperature_c` | `sensor_battery_pct` |
| `gateway_readings` | `phone_battery_pct`, `is_charging`, `network_type`, `location_enabled` | `signal_pct` |
| `location_readings` | `latitude`, `longitude` | `accuracy_m`, `address` |

Iedere insert bevat daarnaast `id`, `device_id` en `recorded_at`. Supabase vult
`received_at` zelf in; de gateway heeft geen recht om die waarde te overschrijven.

## Drempelwaarden aanpassen

De singleton bevat configureerbare waarschuwingen. Pas ze aan in de SQL Editor:

```sql
update public.camper
set battery_warning_pct = 30,
    battery_critical_pct = 15,
    gas_warning_pct = 25,
    gas_critical_pct = 10,
    phone_warning_pct = 20,
    stale_after_minutes = 5,
    offline_after_minutes = 10
where singleton;
```

`critical` moet lager zijn dan `warning`, en `offline_after_minutes` mag niet
lager zijn dan `stale_after_minutes`.

## Brandstofverbruik bijhouden

De brandstofkaart start op **248.654 km** met een tankinhoud van **70 liter**.
De begintank geldt niet als vol. Registreer bij elke tankbeurt de nieuwe
kilometerstand, het aantal getankte liters, het betaalde bedrag en of de tank
daarna volledig vol is.

Het dashboard gebruikt de vol-tot-vol-methode. Een volle tankbeurt vormt een
meetpunt; bij de volgende volle tankbeurt worden alle tussenliggende liters,
inclusief gedeeltelijke tankbeurten, gedeeld door de gereden afstand. Daardoor
verschijnt het eerste betrouwbare verbruik pas na twee volle meetpunten. De
getoonde actieradius is een schatting voor een volle 70-litertank en geen meting
van de actuele tankinhoud.

Bedragen worden standaard in euro ingevoerd. De valutalijst bevat alle actuele
ECB-referentievaluta, met EUR en NOK bovenaan. Voor vreemde valuta haalt de
browser via `https://api.frankfurter.dev/v2` de laatste beschikbare ECB-dagkoers
op. De gebruikte koers, koersdatum en omgerekende eurowaarde worden bij de
tankbeurt opgeslagen en veranderen later niet. De ECB-referentiekoers is
informatief en kan door bank- of kaarttoeslagen afwijken van het afgeschreven
bedrag. Zonder bereikbare koersdienst blijft invoer in EUR beschikbaar, maar kan
een vreemde-valutaboeking niet worden opgeslagen.

De brandstofkaart toont naast de bedragen per tankbeurt ook de totale uitgaven
in euro en de gewogen gemiddelde europrijs per getankte liter.

Alle geautoriseerde gebruikers kunnen de tankhistorie bekijken. Alleen een
gebruiker met de rol `owner` kan tankbeurten toevoegen, wijzigen of verwijderen.
Pas voor een bestaande installatie eerst
`20260801190000_fuel_tracking.sql` toe en publiceer daarna de nieuwe
`index.html`.

## Uitgebreide geschiedenisgrafiek

De dashboard-RPC retourneert per tijdvak het laatste niveau van de huishoudaccu,
gasfles en gatewayaccu, plus het gemiddelde van accuspanning en vermogen:

```text
(bucket_at, battery_soc_pct, gas_fill_pct, battery_voltage_v, average_power_w,
gateway_battery_pct)
```

De responsieve geschiedenisgrafiek gebruikt de vastgepinde Chart.js-versie
`4.5.1` via jsDelivr. De legenda kan reeksen tonen of verbergen; aanwijzen,
aanraken en de pijltoetsen tonen de waarden van een specifiek meetmoment.

Voor een bestaande installatie voer je eerst de nog niet toegepaste migraties
vanaf `supabase/migrations/20260801160000_dashboard_electrical_history.sql` in
bestandsnaamvolgorde uit en publiceer je daarna de nieuwe `index.html`. De oude
frontend negeert de extra velden, waardoor deze uitrolvolgorde achterwaarts
compatibel is.

## Geschatte GPS-afstand en route

De locatiekaart toont voor dezelfde periodekeuze als de geschiedenisgrafiek het
opgeschoonde GPS-spoor en de geschatte gereden afstand. Dit is een GPS-schatting:
de waarde vervangt de kilometerteller en de vol-tot-vol-afstand bij tankbeurten
niet. Er wordt geen externe route-matchingdienst gebruikt; opeenvolgende
geaccepteerde punten worden met rechte lijnsegmenten verbonden.

De RPC gebruikt `recorded_at`, sluit toekomstige metingen uit en accepteert een
onbekende nauwkeurigheid of maximaal 100 meter. Binnen ieder tijdvak van 10
seconden blijft het nauwkeurigste punt over. Verplaatsingen onder de grootste van
10 meter en de nauwkeurigheid van beide punten gelden als stilstandsdrift. Een
tijdsgat van meer dan 30 minuten of een berekende snelheid boven 180 km/u breekt
het spoor en telt niet mee. De afstand wordt met de Haversine-formule berekend
voordat de kaartpunten periode-afhankelijk tot ongeveer 2.500 punten worden
teruggebracht; begin- en eindpunten van ieder ritsegment blijven behouden.

Alle geautoriseerde viewers kunnen dezelfde routehistorie bekijken als de
actuele locatie. Voor een bestaande installatie pas je eerst
`20260801200000_location_history.sql` toe en publiceer je daarna de nieuwe
`index.html`. Bij de omgekeerde volgorde meldt alleen het routeblok dat de RPC
niet beschikbaar is; live status, brandstof en grafieken blijven bruikbaar.

## Beveiligingsmodel

- Anonieme bezoekers hebben geen tabel- of RPC-toegang.
- Alleen Auth-users in `authorized_viewers` kunnen camperdata lezen.
- De gateway kan zijn eigen assignment lezen en alleen metingen onder zijn eigen
  actieve device-ID invoegen.
- De gateway kan geen telemetrie lezen, wijzigen of verwijderen.
- Viewers kunnen via de Data API niets wijzigen.
- De RPC's gebruiken `SECURITY INVOKER`, zodat dezelfde RLS-regels blijven gelden.

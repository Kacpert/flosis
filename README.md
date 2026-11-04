# README

This README would normally document whatever steps are necessary to get the
application up and running.

Things you may want to cover:

* Ruby version

* System dependencies

* Configuration

* Database creation

* Database initialization

* How to run the test suite

* Services (job queues, cache servers, search engines, etc.)

* Deployment instructions

* ...

## API czasu pracy (dla AI)

JSON API pod `https://app.flosis.com/api/v1`, autoryzowane osobistym tokenem
(PAT). Token działa jako jedna osoba w jednym workspace i pozwala tylko na
przeglądanie, dodawanie i usuwanie (do 36 dni wstecz) jej własnych godzin oraz na
odczyt listy jej projektów.

Token wydaje się na serwerze (pokazuje się tylko raz, w bazie jest tylko hash):

```sh
RAILS_ENV=production bin/rails runner 'u = User.find_by!(email_address: "kacper@rubyonsaas.com"); _, raw = ApiToken.issue!(user: u, workspace: u.workspaces.find_by!(name: "Ruby on SaaS"), name: "AI time booking"); puts raw'
```

Unieważnienie: `ApiToken.authenticate("gold_pat_…").revoke!`

Opis do wklejenia w inne AI. Skopiuj przyciskiem w rogu bloku i zamień
`WSTAW_TOKEN` na swój token:

```text
Masz dostęp do API Gold (system do rejestrowania czasu pracy). Dodajesz,
przeglądasz i usuwasz w nim moje godziny pracy.

Adres bazowy: https://app.flosis.com/api/v1
Każde zapytanie musi mieć nagłówek:
  Authorization: Bearer WSTAW_TOKEN
Wysyłasz i dostajesz JSON (Content-Type: application/json).
Czas: ISO 8601. Bez strefy czasowej czas jest liczony według Europe/Warsaw.

1) Lista projektów: GET /projects
   Zwraca {"projects":[{"id","name","client","jira_key","color"}]}.
   Na początku pracy pobierz listę projektów. Jeśli nie wiesz, który projekt
   wybrać, zapytaj mnie.

2) Lista moich wpisów: GET /time_entries
   Parametry w adresie (wszystkie opcjonalne):
   - from, to: daty YYYY-MM-DD, obie włącznie. Domyślnie ostatnie 36 dni.
     Naraz najwyżej 366 dni.
   - project_id: tylko jeden projekt
   Przykład: GET /time_entries?from=2026-11-01&to=2026-11-07&project_id=1
   Zwraca {"from","to","count","truncated","total_minutes","time_entries":[
     {"id","project_id","project","task_key","description","started_at",
      "stopped_at","running","duration_minutes","deletable"}]},
   od najnowszych. "deletable": true oznacza, że wpis można jeszcze usunąć.

3) Dodanie godzin: POST /time_entries
   Pola:
   - project_id (wymagane): id projektu z listy
   - started_at (wymagane): początek, np. "2026-11-04T09:00:00+01:00"
   - koniec, jedno z dwóch:
       stopped_at: koniec, albo
       duration_minutes: liczba całkowita minut
   - description (opcjonalne): co było robione
   - task_key (opcjonalne): klucz zadania z Jiry, np. "DEV-123". Musi istnieć
     w tym projekcie, inaczej dostaniesz błąd. Wtedy wyślij jeszcze raz bez
     task_key i wpisz klucz w description.
   Przykład:
   curl -X POST https://app.flosis.com/api/v1/time_entries \
     -H "Authorization: Bearer WSTAW_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"project_id":1,"started_at":"2026-11-04T09:00:00+01:00","duration_minutes":120,"description":"Code review DEV-123"}'
   Sukces: HTTP 201 i {"time_entry":{...}}, z tymi samymi polami co na liście.

4) Usunięcie wpisu: DELETE /time_entries/{id}
   Przykład:
   curl -X DELETE https://app.flosis.com/api/v1/time_entries/3229 \
     -H "Authorization: Bearer WSTAW_TOKEN"
   Sukces: HTTP 200 i {"deleted":{...dane usuniętego wpisu...}}
   Można usuwać tylko wpisy, których początek jest najwyżej 36 dni temu.
   Starszy wpis zwraca 422 i nie zostaje usunięty.

Zasady:
- Jedno zapytanie dodaje jeden wpis. Kilka dni albo bloków pracy wysyłasz
  kolejnymi zapytaniami.
- Jeden wpis trwa od 1 minuty do 24 godzin, a koniec musi być po początku.
- Wpisów nie da się edytować. Poprawka to usunięcie starego wpisu i dodanie
  nowego.
- Zanim dodasz wpisy, sprawdź listę z danego dnia, żeby nie zdublować godzin.
- Zanim cokolwiek dodasz albo usuniesz, pokaż mi, co zamierzasz zrobić
  (projekt, data, godziny, opis), i poczekaj na moje potwierdzenie.
  Usunięcia nie da się cofnąć.
- Błędy: {"error":"...","details":[...]}.
  401 = zły token, 403 = brak uprawnień, 404 = nie ma takiego wpisu albo nie
  jest mój, 422 = złe dane (popraw według komunikatu), 429 = za dużo zapytań
  (limit 120 na minutę).
```

# Ega

A phone-first web app for personal money: split every income the moment it
arrives, spend the Enjoy share without guilt, fill a Buy List, build an
emergency fund and keep track of investments. Money can sit in a bank account,
MoMo or cash.

Sinatra + Sequel + SQLite, served by Passenger at https://ega.anmgw.com. It
installs to a phone's home screen as a web app.

## How it works

Every cedi has a **job** (a pot) and a **place** (an account):

| Pot | Default share | What it's for | Lives in |
|---|---|---|---|
| Future Me | 20% | Emergency fund, then investments | Bank savings |
| Buy List | 10% | Fills the Buy List, top item first | Bank savings |
| Living | 50% | Rent, transport, food, data, bills | Anywhere |
| Enjoy | 20% | Guilt-free spending | Anywhere |

Shares and homes are editable in Settings. Accounts start as Bank savings,
MoMo and Cash (add more, e.g. Telecel Cash), plus one Investments account that
holds what is invested.

- **Money in** splits the income across the pots, in the account it arrived in.
  If a monthly living target is set and Living has already received it, Living's
  share goes to Future Me instead.
- **Suggested moves** on the home screen show money sitting in the wrong account
  (e.g. Future Me's share still in MoMo). "Done, I moved it" records the transfer.
- **Safe to spend today** is the Enjoy pot spread over the days to the next
  payday (or the end of the month when income is irregular).
- **Check a balance**: enter what the bank or MoMo app shows and the gap is
  recorded, so small Living costs don't all need logging.
- **Buy List**: new wants wait 48 hours (configurable) before joining the list;
  the Buy List pot fills items in order, with "ready around" dates.
- **Investments**: T-bills, bonds, funds, shares, Tier 3, fixed deposits. Maturity
  reminders, value updates, top-ups, cash-outs and roll-overs. Holdings marked
  as quick to withdraw count towards the emergency fund.
- **Paste an SMS**: reads MTN MoMo, Telecel Cash, AT Money and bank alerts into
  a prefilled entry, and warns about repeats by transaction ID.
- **SMS inbox**: each user can make a private link (`/inbox/setup`) that their
  phone forwards money SMS to: MacroDroid on Android, Shortcuts on iPhone (a
  website can't read SMS itself). `POST /sms/<token>` takes the text as a `text`
  form or JSON field, or as a plain-text body. Only messages with an amount are
  kept, repeats are skipped, and each waits in `/inbox` until confirmed: money
  in splits with one tap, spending needs a pot. The token never appears in the log.
- **Monthly review**, **Activity** (filter by month, pot, account, type) and
  **Investing in Ghana** (a short guide with red flags).

Amounts are stored as whole pesewas. Each event is one `transactions` row plus
signed `entries`, one per pot and account it touches; balances are sums of
entries (`lib/plan.rb` reads them, `lib/ledger.rb` writes them). Deleting an
event reverses it, and Buy List purchases and investment changes keep a snapshot
so deleting them puts the item or investment back.

## Setup

```bash
cd /opt/yesuko/webapps/ega
rvm use ruby-4.0.5@ega --create
bundle install
cp .env.example .env          # then set SESSION_SECRET (64+ characters):
ruby -rsecurerandom -e "puts SecureRandom.hex(48)"
bundle exec ruby bin/migrate.rb
bundle exec ruby bin/create_user.rb "Your Name" you@example.com 'a-long-password'
```

Anyone can also create an account at `/signup`. Each gets their own accounts,
pots and data. A hidden field catches form-filling bots, and one IP address can
create at most 5 accounts a day (`SIGNUPS_PER_IP_PER_DAY` in `app.rb`).

There is no self-service password reset yet: running `create_user.rb` with an
existing email sets a new password for that account.

The database is the single file `db/ega.sqlite3` (WAL mode, so you'll also see
`-wal` and `-shm` files next to it). Don't delete those while the app runs.

## Serving it

nginx + Passenger (`/etc/nginx/sites-available/ega.conf`):

```nginx
server {
    listen 443 ssl http2;
    server_name ega.anmgw.com;
    include /etc/nginx/ssl/cert.conf;

    rails_env production;
    root /opt/yesuko/webapps/ega/public;
    passenger_enabled on;
    passenger_ruby /home/yesuko/.rvm/wrappers/ruby-4.0.5@ega/ruby;
}
```

In production the login cookie is HTTPS-only, templates are cached and errors
show a friendly page (details in `log/application.log`).

- After code changes: `touch tmp/restart.txt`
- After pulling new migrations: `bundle exec ruby bin/migrate.rb`, then restart.
- nginx serves `public/` itself, so the app folder must be readable by others
  (except `.env`, the database and logs):
  `find . \( -name .env -o -name '*.sqlite3*' -o -path ./log -o -path ./.git \) -prune -o -exec chmod o+rX {} +`

To run it without Passenger: `bundle exec rackup -p 4600 -o 127.0.0.1` (development
mode; open http://localhost:4600, forwarding port 4600 from VS Code).

## Backups

`bin/backup.sh` copies the database to `~/backups/ega` (safe while the app runs)
and keeps the newest 30. To run it daily at 02:15:

```bash
(crontab -l 2>/dev/null; echo '15 2 * * * /opt/yesuko/webapps/ega/bin/backup.sh >/dev/null') | crontab -
```

To restore a backup (safe while the app runs), then restart:

```bash
sqlite3 db/ega.sqlite3 ".restore '/home/yesuko/backups/ega/ega-2026-10-21-0215.sqlite3'"
touch tmp/restart.txt
```

## Tests

```bash
bundle exec rake test
```

They test the money logic (split, safe to spend, suggested moves, Buy List,
emergency fund, ledger writes and undo, investments, SMS reading) against an
in-memory database, so they never touch real data.

## Layout

```
app.rb              settings, helpers and routes
lib/plan.rb         balances and figures (split, safe to spend, moves, Buy List, emergency fund, review)
lib/ledger.rb       writes money events
lib/sms_parser.rb   reads pasted MoMo/bank SMS
lib/money.rb        pesewas <-> "1,200.50"
models/             Sequel models
views/              ERB templates
public/             CSS, JS, PWA manifest, service worker, icons
db/migrate/         Sequel migrations
bin/                migrate.rb, create_user.rb, backup.sh
test/               Minitest tests
```

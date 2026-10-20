# Ega — Money Plan

A phone-first web app for personal money: split every income the moment it
arrives, spend the Enjoy share without guilt, fill a Buy List, build an
emergency fund and keep track of investments. Money can sit in a bank account,
MoMo or cash.

Sinatra + Sequel + PostgreSQL (SQLite works for trying it out). It installs to
a phone's home screen as a web app.

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
- **Monthly review**, **Activity** (filter by month, pot, account, type) and
  **Investing in Ghana** (a short guide with red flags).

Amounts are stored as whole pesewas. Each event is one `transactions` row plus
signed `entries`, one per pot and account it touches; balances are sums of
entries (`lib/plan.rb` reads them, `lib/ledger.rb` writes them). Deleting an
event reverses it, and Buy List purchases and investment changes keep a snapshot
so deleting them puts the item or investment back.

## Setup

### 1. Ruby

```bash
rvm use ruby-4.0.5@money_plan --create
bundle install
```

### 2. Database

To try it out, a SQLite file is enough (the default in `.env.example`).

On the server, use Postgres (port 4044 here). Create a role and database
(needs sudo):

```bash
GENPASS=$(openssl rand -hex 24)
sudo -u postgres psql -p 4044 -c "CREATE ROLE money_plan LOGIN PASSWORD '${GENPASS}';"
sudo -u postgres psql -p 4044 -c "CREATE DATABASE money_plan OWNER money_plan;"
echo "DATABASE_URL=postgres://money_plan:${GENPASS}@localhost:4044/money_plan"
```

### 3. `.env`

```bash
cp .env.example .env
```

Set `DATABASE_URL` and a `SESSION_SECRET` of at least 64 characters
(`ruby -rsecurerandom -e "puts SecureRandom.hex(48)"`). Behind HTTPS, set
`APP_ENV=production` so the login cookie is only sent over HTTPS.

### 4. Tables and a login

```bash
bundle exec ruby bin/migrate.rb
bundle exec ruby bin/create_user.rb "Your Name" you@example.com 'a-long-password'
```

Running `create_user.rb` again with the same email resets the password.

## Running

```bash
bundle exec rackup -p 4600 -o 127.0.0.1
```

Open http://localhost:4600 (from VS Code Remote-SSH, forward port 4600 in the
Ports tab). Log in, then **Starting balances** records what you hold today.

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
bin/                migrate.rb, create_user.rb
```

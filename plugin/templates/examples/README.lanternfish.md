# Lanternfish

You follow a dozen blogs and open fewer of them every week. Give Lanternfish a list of feeds and it emails you one short digest every Monday morning, with the best new posts grouped by site.

![A weekly digest email with three blog names, each followed by two linked post titles and a one-line summary](docs/images/digest.png)

- **One email a week**: new posts from all your feeds arrive in a single message on Monday at 7:00 your time.
- **Ranked, not dumped**: each feed contributes at most two posts, picked by how many other feeds link to them.
- **Plain feeds in, plain mail out**: it reads RSS and Atom, and the digest is ordinary HTML that any mail app can show.
- **Skips what you have seen**: a post that appeared in an earlier digest never shows up again.

<p><img src="docs/images/inbox.png" width="72%" alt="A desktop inbox with the Monday digest open, showing grouped posts"><img src="docs/images/phone.png" width="24%" alt="The same digest on a phone, in a single column"></p>

Lanternfish reads public feeds only; pages behind a login are skipped.

## How it works

```
feeds.txt ──► fetch each feed ──► rank and trim ──► build HTML digest
                                                         └─► send through your own SMTP account
```

There is no server and no database: a small state file on your computer remembers which posts were already sent.

## Install

You need Python 3.11 or newer and an email account that allows SMTP sign-in.

1. Download the latest release from the repository's **Releases** page and unzip it.
2. Open a terminal in the unzipped folder and run `python -m pip install .`.
3. Copy `feeds.example.txt` to `feeds.txt` and put one feed address on each line.
4. Copy `.env.example` to `.env`, then fill in your SMTP server, user name and an app password. In Gmail, create the password under **Google Account → Security → App passwords**.
5. Run `lanternfish --dry-run` to print this week's digest without sending it, then `lanternfish` to send it.
6. To make it weekly, schedule `lanternfish` for Monday morning with cron, or with **Task Scheduler → Create Basic Task** on Windows.

## Privacy & security

- Your feed list, the state file and your mail password stay on your computer. The password is read from `.env` and used only to sign in to your own mail server.
- Lanternfish contacts the feed addresses you list and your SMTP server, and nothing else. It has no analytics and no account of its own.
- The digest contains only titles, links and the first sentence of each post, copied from the feeds you chose.
- Keep `.env` out of version control; the repository's `.gitignore` already excludes it.

## License

[MIT](LICENSE). Feed parsing uses the open-source `feedparser` library.

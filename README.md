# Claude Accounts

A macOS menu bar app that switches Claude Desktop between accounts without
logging out, and carries open Code-tab sessions over to the account you switch
to.

Not affiliated with Anthropic. It relies on undocumented Claude Desktop
internals, so a Desktop update can break it.

## What it does

- Lists the accounts it has a saved login for and switches to one with a click:
  Claude quits, the login is swapped, and Claude opens on the other account.
- Offers the open Code-tab sessions of the account you are leaving (others can
  be ticked too) and moves them to the new one.
- Adds an account: it saves the current login and opens Claude signed out, so
  you sign in by hand once. From then on, switching needs no sign-in.
- Brings open sessions from other accounts to the current one without switching.
- Shows each account's usage (the 5-hour and weekly windows, plus the busiest
  per-model weekly window) so you can see which account has room left.
- Speaks English and Spanish, following the system language.

## How it works

Claude Desktop keeps its data in `~/Library/Application Support/Claude`:

- The login is the `Cookies` database (the claude.ai `sessionKey` cookie) plus
  four keys in `config.json`: `oauth:tokenCache`, `oauth:tokenCacheV2`,
  `lastKnownAccountUuid` and `bootSideSessions`. A switch saves them for the
  current account under
  `~/Library/Application Support/ClaudeAccounts/profiles/<account>/` and puts
  the target account's back. The state from before the last switch is kept in
  `backup/`.
- Each Code-tab session is a `local_*.json` file under
  `claude-code-sessions/<account>/<org>/`. Moving the file moves the session;
  the transcripts in `~/.claude/projects` are shared by every account. Archived
  sessions are never moved.
- Usage comes from `https://claude.ai/api/organizations/<org>/usage`, called
  with each account's `sessionKey` cookie. Chromium encrypts that cookie with a
  key derived from the `Claude Safe Storage` keychain item, so the first time
  macOS asks whether the app may read that item. The key and the cookies are
  only kept in memory.
- The active account and organization come from the last
  `[LocalSessionManager] Initialization succeeded` line in
  `~/Library/Logs/Claude/main*.log`.

Every change happens with Claude closed. Reading usage never changes anything.

## Caveats

- Never use Claude's own "Log out" on an account you want to keep: it revokes
  the session on the server and the saved login stops working. If that happens,
  sign in again and the next switch saves the new login.
- A saved login expires like any other (about a month); Claude then asks you to
  sign in.
- Sidebar pins and groups may not follow a moved session.
- Account and organization names live in `labels.json` in the storage folder.
  The current account can be renamed from the menu.

## Localization

The English text in the code is the key. Translations live in
`Resources/Localization/<language>.lproj/Localizable.strings`, and
`InfoPlist.strings` there localizes the app's name. To add a language, add a
folder and run `scripts/check-localizations`, which lists the keys each
language is missing or no longer uses.

## Building

Requires macOS 14 or later and Xcode with Swift 6.

```bash
swift test                   # core tests
scripts/check-localizations  # every language has every key
scripts/build-app            # build/Claude Accounts.app
scripts/build-app --install  # copy to ~/Applications and open it
scripts/make-icon            # regenerate Resources/AppIcon.icns
```

# nu-dir-history

Browser-style back/forward navigation over your `cd` history in Nushell.

nu-dir-history records every directory you visit in the current session and
lets you move backward and forward through them with Ctrl+Shift+Left and
Ctrl+Shift+Right, like the back and forward buttons of a web browser. It is a
Nushell port of [zsh-dir-history](https://github.com/yutkat/zsh-dir-history).

- The command line you are typing is kept while you navigate.
- Directories that no longer exist are skipped and dropped from the history.
- Existing `env_change.PWD` hooks (zoxide, for example) keep working.

## Requirements

- The latest Nushell release (0.116.0 or newer)
- Linux; tested in WezTerm

## Install

Clone the repository, then add to your `config.nu`:

```nu
use /path/to/nu-dir-history/nu-dir-history
nu-dir-history enable
```

Or install it with [nupm](https://github.com/nushell/nupm) from the clone
(`$env.NUPM_HOME/modules` must be in `$env.NU_LIB_DIRS`):

```nu
nupm install /path/to/nu-dir-history --path
```

and add to your `config.nu`:

```nu
use nu-dir-history
nu-dir-history enable
```

`use` alone changes nothing. To try it without your own configuration:

```sh
nu --config examples/minimal-config.nu
```

## Usage

| Key              | Action                            |
| ---------------- | --------------------------------- |
| Ctrl+Shift+Left  | go back to the previous directory |
| Ctrl+Shift+Right | go forward to the next directory  |

The keys work in Emacs mode and in Vi insert and normal mode.

```nu
nu-dir-history enable                                    # default keys, 100 entries
nu-dir-history enable --back-key alt+b --forward-key alt+f
nu-dir-history enable --max-size 50                      # keep at most 50 entries
nu-dir-history enable --no-keybindings                   # record only; use the commands below
nu-dir-history back                                      # same as the back key; `back 2` goes two entries back
nu-dir-history forward                                   # same as the forward key
nu-dir-history list                                      # the history, oldest first; `current` marks where you are
nu-dir-history reset                                     # keep only the current directory
nu-dir-history status                                    # current state and settings
nu-dir-history disable                                   # remove the keybindings and the hook
```

Changing to a new directory after going back drops the entries ahead of the
current one, as in a browser. When the history is full, the oldest entries are
dropped.

Running `enable` again replaces the previous installation without duplicates
and keeps the recorded history (trimmed to a smaller `--max-size`). `disable`
removes only the keybindings and the hook that `enable` added; keybindings and
hooks you added yourself, before or after, are kept.

### Keys

`--back-key` and `--forward-key` take `[modifier+]...key`: modifiers `ctrl`
(or `control`), `alt`, `shift`, in any order; keys are a single character or
one of `left`, `right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown`,
`enter`, `tab`, `backtab`, `backspace`, `delete`, `insert`, `esc`, `space`,
`f1` ... `f12`. Specs are case insensitive (`ALT+B` is `alt+b`). For the `+`
key itself, write it after a modifier, as in `ctrl++`; a bare `+` is rejected.

## How it works

- `enable` appends a hook to `$env.config.hooks.env_change.PWD` that records
  each new directory, after any hooks already there. The hook is a record whose
  `name` field is `nu_dir_history`, which is how `disable` finds it again.
- The keybindings are named `nu_dir_history_back` and
  `nu_dir_history_forward`. They run an `executehostcommand`, which changes
  the directory without touching the command line, so the prompt updates and
  the line you were typing (and the cursor position) stays.
- The history is kept in `$env.__NU_DIR_HISTORY`, for the current session
  only.

## Known issues

- Assigning a new list to `$env.config.hooks.env_change.PWD` after `enable`
  (instead of appending to it) removes the hook; `status` then shows
  `hook: false`. Run `enable` after such configuration, or append with `++=`.
- In Vi normal mode, the line editor returns to insert mode after navigating.
- Several `cd`s in one command line are recorded as one change, because
  Nushell runs `env_change` hooks once before the next prompt.

## Development

```sh
nu tests/run.nu
```

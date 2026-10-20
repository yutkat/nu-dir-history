# Pure helpers for nu-dir-history: key parsing, keybinding generation and
# history updates. Nothing here touches `$env`, so it can be tested directly.

# Prefix of every keybinding name nu-dir-history owns.
export const NAME_PREFIX = "nu_dir_history_"

# Value of the `name` field that marks the `env_change.PWD` hook we add.
export const HOOK_NAME = "nu_dir_history"

export const DEFAULT_BACK_KEY = "ctrl+shift+left"
export const DEFAULT_FORWARD_KEY = "ctrl+shift+right"
export const DEFAULT_MAX_SIZE = 100

# Edit modes the keybindings are installed in.
export const MODES = [emacs vi_insert vi_normal]

# Modifier names accepted in key specs. Nushell only accepts combinations in
# some orders (`control_alt_shift` but not `alt_control_shift`), so they are
# joined in the order of this table's values: control, alt, shift.
const MODIFIERS = {ctrl: control, control: control, alt: alt, shift: shift}

const NAMED_KEYS = [
    backspace enter left right up down home end pageup pagedown tab backtab
    delete insert esc space f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12
]

# Whether a keybinding entry was created by nu-dir-history.
export def is-our-keybinding []: record -> bool {
    ($in.name? | default "" | into string) starts-with $NAME_PREFIX
}

# Whether an `env_change.PWD` hook entry was created by nu-dir-history.
export def is-our-hook []: any -> bool {
    let h = $in
    ($h | describe --detailed).type == record and ($h.name? == $HOOK_NAME)
}

# Parse a key spec like `ctrl+shift+left` or `alt+b` (case insensitive) into a
# keybinding modifier and keycode.
export def parse-key-spec [spec: string]: nothing -> record {
    let parts = if ($spec | str ends-with "++") {
        $spec | str replace --regex '\+\+$' '' | split row "+" | append "+"
    } else {
        $spec | split row "+"
    }
    let key = $parts | last | str trim
    let mods = $parts | drop 1 | each { str trim | str lowercase }
    if ($key | is-empty) {
        error make {msg: $"invalid key '($spec)': no key after the modifiers"}
    }
    let unknown = $mods | where $it not-in $MODIFIERS
    if ($unknown | is-not-empty) {
        error make {msg: $"invalid key '($spec)': unknown modifier '($unknown | first)'"}
    }
    let modifier = $mods | each {|m| $MODIFIERS | get $m } | uniq
    | sort-by {|m| [control alt shift] | enumerate | where item == $m | get 0.index }
    | str join "_"
    let keycode = if ($key | str length) == 1 {
        $"char_($key | str lowercase)"
    } else if ($key | str lowercase) in $NAMED_KEYS {
        $key | str lowercase
    } else {
        error make {msg: $"invalid key '($spec)': unknown key '($key)'"}
    }
    {modifier: ($modifier | if ($in | is-empty) { "none" } else { $in }), keycode: $keycode}
}

# The keybindings for the back and forward keys (none for a null key).
export def generate-keybindings [back_key: any, forward_key: any]: nothing -> list<record> {
    [[name key step]; [back $back_key -1] [forward $forward_key 1]]
    | where key != null
    | each {|b|
        {name: $"($NAME_PREFIX)($b.name)"}
        | merge (parse-key-spec $b.key)
        | merge {
            mode: $MODES
            # Runs through a closure kept in the environment, so the binding
            # works however the module was imported. A host command keeps the
            # current command line.
            event: {send: executehostcommand, cmd: $"do --env $env.__NU_DIR_HISTORY.go \(($b.step))"}
        }
    }
}

# Record `dir` as the newest entry after the current one, dropping any forward
# entries and keeping at most `max_size` entries.
export def push-entry [dir: string, max_size: int]: record -> record {
    let h = $in
    if ($h.stack | get --optional $h.index) == $dir {
        return $h
    }
    let stack = $h.stack | first ($h.index + 1) | append $dir | last $max_size
    $h | merge {stack: $stack, index: (($stack | length) - 1)}
}

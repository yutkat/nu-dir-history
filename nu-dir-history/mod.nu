# nu-dir-history: browser-style back/forward over the directories visited in
# the current session.
#
# `use nu-dir-history` only defines commands; nothing changes until
# `nu-dir-history enable` is run.

use lib.nu *

def state []: nothing -> record {
    $env.__NU_DIR_HISTORY? | default {enabled: false}
}

def require-enabled []: nothing -> record {
    let st = state
    if not $st.enabled {
        error make {msg: "nu-dir-history is not enabled; run `nu-dir-history enable` first"}
    }
    $st
}

# Replace the keybinding list. Assigning a list to `$env.config.keybindings`
# merges it into the current one (Nushell >= 0.116), so entries can only be
# dropped by clearing the list first.
def --env set-keybindings [bindings: list]: nothing -> nothing {
    $env.config.keybindings = []
    if ($bindings | is-not-empty) {
        $env.config.keybindings = $bindings
    }
}

# The current `env_change.PWD` hooks as a list, and whether the key existed.
# Nushell >= 0.116 only accepts a list there; a lone closure or record (allowed
# by older versions) is treated as a one-element list.
def pwd-hooks []: nothing -> record {
    let current = $env.config.hooks.env_change.PWD?
    match ($current | describe --detailed).type {
        "nothing" => {shape: absent, hooks: []}
        "list" => {shape: list, hooks: $current}
        _ => {shape: list, hooks: [$current]}
    }
}

def --env set-pwd-hooks [hooks: any]: nothing -> nothing {
    $env.config.hooks.env_change = if $hooks == null {
        $env.config.hooks.env_change | reject --optional PWD
    } else {
        $env.config.hooks.env_change | upsert PWD $hooks
    }
}

# Remove our keybindings and hook, and the PWD key if enable created it.
def --env uninstall [hook_shape: string]: nothing -> nothing {
    if ($env.config.keybindings | any {|kb| $kb | is-our-keybinding }) {
        set-keybindings ($env.config.keybindings | where {|kb| not ($kb | is-our-keybinding) })
    }
    let hooks = pwd-hooks
    if ($hooks.hooks | any {|h| $h | is-our-hook }) {
        let others = $hooks.hooks | where {|h| not ($h | is-our-hook) }
        if $hook_shape == "absent" and ($others | is-empty) {
            set-pwd-hooks null
        } else {
            set-pwd-hooks $others
        }
    }
}

# Move `step` entries through the history (negative is back), skipping and
# dropping entries whose directory can no longer be entered.
def --env go [step: int]: nothing -> nothing {
    mut st = require-enabled
    if $step == 0 {
        return
    }
    let dir = if $step < 0 { -1 } else { 1 }
    for _ in 1..($step | math abs) {
        loop {
            let i = $st.index + $dir
            if $i < 0 or $i >= ($st.stack | length) {
                $env.__NU_DIR_HISTORY = $st
                return
            }
            let target = $st.stack | get $i
            let moved = try { cd $target; true } catch { false }
            if $moved {
                # The PWD hook then finds the current entry and records nothing.
                $st.index = $i
                break
            }
            $st.stack = $st.stack | drop nth $i
            if $dir < 0 { $st.index -= 1 }
        }
    }
    $env.__NU_DIR_HISTORY = $st
}

# Enable directory history for the current session.
#
# Records every directory change in an `env_change.PWD` hook (added after any
# existing PWD hooks) and binds the back and forward keys in Emacs and Vi
# modes. Running it again replaces the previous installation instead of adding
# duplicates and keeps the recorded history.
export def --env enable [
    --back-key: string # Key that goes back (default: ctrl+shift+left)
    --forward-key: string # Key that goes forward (default: ctrl+shift+right)
    --no-keybindings # Install no keybindings; use `nu-dir-history back`/`forward` instead
    --max-size: int # Number of entries kept (default: 100)
]: nothing -> nothing {
    let max_size = $max_size | default $DEFAULT_MAX_SIZE
    if $max_size < 1 {
        error make {msg: $"--max-size must be at least 1, got ($max_size)"}
    }
    let keys = if $no_keybindings {
        {back: null, forward: null}
    } else {
        {back: ($back_key | default $DEFAULT_BACK_KEY), forward: ($forward_key | default $DEFAULT_FORWARD_KEY)}
    }
    # Fails on an invalid key spec before anything is changed.
    let bindings = generate-keybindings $keys.back $keys.forward

    let old = state
    let history = if $old.enabled {
        uninstall $old.hook_shape
        let stack = $old.stack | last $max_size
        {stack: $stack, index: ([($old.index - ($old.stack | length) + ($stack | length)) 0] | math max)}
    } else {
        {stack: [$env.PWD], index: 0}
    }

    set-keybindings ($env.config.keybindings ++ $bindings)
    let hooks = pwd-hooks
    let hook = {
        name: $HOOK_NAME
        code: {|before, after|
            let st = state
            if $st.enabled {
                $env.__NU_DIR_HISTORY = $st | push-entry $after $st.max_size
            }
        }
    }
    set-pwd-hooks ($hooks.hooks ++ [$hook])

    $env.__NU_DIR_HISTORY = {
        enabled: true
        back_key: $keys.back
        forward_key: $keys.forward
        max_size: $max_size
        hook_shape: $hooks.shape
        go: {|step| go $step }
        ...$history
    }
}

# Disable directory history and remove the keybindings and hook enable added.
#
# Other keybindings and PWD hooks are kept, including ones added after enable.
export def --env disable []: nothing -> nothing {
    let st = state
    uninstall ($st.hook_shape? | default "list")
    $env.__NU_DIR_HISTORY = {enabled: false}
}

def check-steps [steps: int]: nothing -> int {
    if $steps < 1 {
        error make {msg: $"steps must be at least 1, got ($steps)"}
    }
    $steps
}

# Go back to the previous directory in the history.
export def --env back [
    steps: int = 1 # Number of entries to go back
]: nothing -> nothing {
    go (0 - (check-steps $steps))
}

# Go forward to the next directory in the history.
export def --env forward [
    steps: int = 1 # Number of entries to go forward
]: nothing -> nothing {
    go (check-steps $steps)
}

# List the directory history, oldest first; `current` marks where you are.
export def list []: nothing -> table<index: int, path: string, current: bool> {
    let st = require-enabled
    $st.stack | enumerate | each {|e| {index: $e.index, path: $e.item, current: ($e.index == $st.index)} }
}

# Clear the directory history, keeping only the current directory.
export def --env reset []: nothing -> nothing {
    let st = require-enabled
    $env.__NU_DIR_HISTORY = $st | merge {stack: [$env.PWD], index: 0}
}

# Show whether nu-dir-history is enabled and what it installed.
export def status []: nothing -> record {
    let st = state
    {
        enabled: $st.enabled
        back_key: ($st.back_key? | default null)
        forward_key: ($st.forward_key? | default null)
        max_size: ($st.max_size? | default null)
        entries: ($st.stack? | default [] | length)
        index: ($st.index? | default null)
        keybindings: ($env.config.keybindings | where {|kb| $kb | is-our-keybinding } | length)
        hook: (pwd-hooks | get hooks | any {|h| $h | is-our-hook })
    }
}

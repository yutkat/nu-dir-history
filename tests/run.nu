# Test entry point: `nu tests/run.nu`. Exits non-zero when a test fails.
#
# These tests exercise key parsing, history updates and enable/disable on
# `$env.config` in-process. Hooks only fire and keybindings only run in an
# interactive session, so `cd-hooked` runs the PWD hooks the way the REPL
# would after a directory change.

use std/assert

const ROOT = path self ..
use ($ROOT | path join nu-dir-history)
use ($ROOT | path join nu-dir-history lib.nu) *

def ours []: list -> list { where {|kb| $kb | is-our-keybinding } }

def our-hooks []: nothing -> list {
    $env.config.hooks.env_change.PWD? | default [] | where {|h| $h | is-our-hook }
}

def user-binding [name: string, modifier: string, keycode: string]: nothing -> record {
    {name: $name, modifier: $modifier, keycode: $keycode, mode: emacs, event: {send: clearscreen}}
}

# Run the PWD hooks like the REPL does when PWD changed from `before`.
def --env fire-pwd-hooks [before: any]: nothing -> nothing {
    for h in ($env.config.hooks.env_change.PWD? | default []) {
        let code = if ($h | describe --detailed).type == record { $h.code } else { $h }
        do --env $code $before $env.PWD
    }
}

def --env cd-hooked [dir: string]: nothing -> nothing {
    let before = $env.PWD
    cd $dir
    fire-pwd-hooks $before
}

# Press the back (-1) or forward (1) key: run the keybinding's command, then the hooks.
def --env press [step: int]: nothing -> nothing {
    let before = $env.PWD
    do --env $env.__NU_DIR_HISTORY.go $step
    fire-pwd-hooks $before
}

def history-names []: nothing -> list<string> {
    nu-dir-history list | get path | path basename
}

# A fresh directory with subdirectories a, b, c and d.
def scratch []: nothing -> string {
    let root = $env.__TEST_ROOT | path join (random uuid)
    for d in [a b c d] { mkdir ($root | path join $d) }
    $root
}

# --- key specs --------------------------------------------------------------

def "test key specs parse to modifier and keycode" [] {
    assert equal (parse-key-spec ctrl+shift+left) {modifier: control_shift, keycode: left}
    assert equal (parse-key-spec Shift+Ctrl+Right) {modifier: control_shift, keycode: right}
    assert equal (parse-key-spec alt+b) {modifier: alt, keycode: char_b}
    assert equal (parse-key-spec ALT+B) {modifier: alt, keycode: char_b}
    assert equal (parse-key-spec ctrl+alt+b) {modifier: control_alt, keycode: char_b}
    assert equal (parse-key-spec shift+alt+ctrl+x) {modifier: control_alt_shift, keycode: char_x}
    assert equal (parse-key-spec alt+shift+left) {modifier: alt_shift, keycode: left}
    assert equal (parse-key-spec F5) {modifier: none, keycode: f5}
    assert equal (parse-key-spec "ctrl+,") {modifier: control, keycode: "char_,"}
    assert equal (parse-key-spec ctrl++) {modifier: control, keycode: "char_+"}
}

def "test invalid key specs are rejected" [] {
    for spec in ["" ctrl+ hyper+x super+x ctrl+foo f13] {
        let msg = try { parse-key-spec $spec; null } catch {|e| $e.msg }
        assert ($msg != null) $"accepted invalid spec '($spec)'"
        assert ($msg | str starts-with "invalid key") $msg
    }
}

# --- keybindings ------------------------------------------------------------

def "test generated keybindings are named and run the stored closure" [] {
    let b = generate-keybindings ctrl+shift+left ctrl+shift+right
    assert equal ($b | get name) [nu_dir_history_back nu_dir_history_forward]
    assert ($b | all {|kb| $kb | is-our-keybinding })
    assert equal ($b | get 0.mode) [emacs vi_insert vi_normal]
    assert equal ($b | get event) [
        {send: executehostcommand, cmd: "do --env $env.__NU_DIR_HISTORY.go (-1)"}
        {send: executehostcommand, cmd: "do --env $env.__NU_DIR_HISTORY.go (1)"}
    ]
}

def "test a null key generates no keybinding" [] {
    assert equal (generate-keybindings null alt+f | get name) [nu_dir_history_forward]
    assert equal (generate-keybindings null null) []
}

# --- history updates --------------------------------------------------------

def "test push appends after the current entry" [] {
    let h = {stack: [/a /b], index: 1}
    assert equal ($h | push-entry /c 100) {stack: [/a /b /c], index: 2}
}

def "test push of the current entry changes nothing" [] {
    let h = {stack: [/a /b /c], index: 1}
    assert equal ($h | push-entry /b 100) $h
}

def "test push drops forward entries" [] {
    let h = {stack: [/a /b /c /d], index: 1}
    assert equal ($h | push-entry /x 100) {stack: [/a /b /x], index: 2}
}

def "test push keeps at most max size entries" [] {
    let h = {stack: [/a /b /c], index: 2, other: 1}
    assert equal ($h | push-entry /d 3) {stack: [/b /c /d], index: 2, other: 1}
}

# --- enable / disable -------------------------------------------------------

def --env "test use alone does not change config" [] {
    # The module is already imported at the top of this file.
    assert equal ($env.config.keybindings | ours | length) 0
    assert equal (our-hooks | length) 0
    assert equal (nu-dir-history status | get enabled) false
}

def --env "test enable installs keybindings and a hook after existing hooks" [] {
    let other = {|before, after| $env.OTHER_HOOK = $after }
    $env.config.hooks.env_change.PWD = [$other]
    nu-dir-history enable
    let hooks = $env.config.hooks.env_change.PWD
    assert equal ($hooks | length) 2
    assert equal ($hooks | first) $other
    assert ($hooks | last | is-our-hook)
    let kb = $env.config.keybindings | ours
    assert equal ($kb | select name modifier keycode) [
        {name: nu_dir_history_back, modifier: control_shift, keycode: left}
        {name: nu_dir_history_forward, modifier: control_shift, keycode: right}
    ]
    let st = nu-dir-history status
    assert equal $st {
        enabled: true, back_key: ctrl+shift+left, forward_key: ctrl+shift+right
        max_size: 100, entries: 1, index: 0, keybindings: 2, hook: true
    }
}

def --env "test enable works without a PWD hook list" [] {
    $env.config.hooks.env_change = $env.config.hooks.env_change | reject --optional PWD
    nu-dir-history enable
    assert equal (our-hooks | length) 1
    assert equal ($env.config.hooks.env_change.PWD | length) 1
}

def --env "test existing hooks keep running" [] {
    let dir = scratch
    cd $dir
    $env.config.hooks.env_change.PWD = [{|before, after| $env.OTHER_HOOK = $after }]
    nu-dir-history enable
    cd-hooked a
    assert equal $env.OTHER_HOOK ($dir | path join a)
    press (-1)
    assert equal $env.OTHER_HOOK $dir
}

def --env "test enable is idempotent and keeps the history" [] {
    let dir = scratch
    cd $dir
    nu-dir-history enable
    cd-hooked a
    let kb = $env.config.keybindings
    let hooks = $env.config.hooks.env_change.PWD
    nu-dir-history enable
    assert equal $env.config.keybindings $kb
    assert equal ($env.config.hooks.env_change.PWD | length) ($hooks | length)
    assert equal (our-hooks | length) 1
    assert equal (history-names) [($dir | path basename) a]
}

def --env "test enable with other keys replaces keybindings" [] {
    nu-dir-history enable
    nu-dir-history enable --back-key alt+b --forward-key alt+f
    let kb = $env.config.keybindings | ours
    assert equal ($kb | select name modifier keycode) [
        {name: nu_dir_history_back, modifier: alt, keycode: char_b}
        {name: nu_dir_history_forward, modifier: alt, keycode: char_f}
    ]
    assert equal (nu-dir-history status | select back_key forward_key) {back_key: alt+b, forward_key: alt+f}
}

def --env "test enable without keybindings" [] {
    nu-dir-history enable
    nu-dir-history enable --no-keybindings
    assert equal ($env.config.keybindings | ours | length) 0
    assert equal (our-hooks | length) 1
    assert equal (nu-dir-history status | select back_key forward_key keybindings) {back_key: null, forward_key: null, keybindings: 0}
}

def --env "test enable rejects invalid options without changes" [] {
    nu-dir-history enable
    let before = $env.config
    let before_state = $env.__NU_DIR_HISTORY
    assert error { nu-dir-history enable --back-key ctrl+nope }
    assert error { nu-dir-history enable --max-size 0 }
    assert equal $env.config $before
    assert equal ($env.__NU_DIR_HISTORY | reject go) ($before_state | reject go)
}

def --env "test enable with a smaller max size trims the history" [] {
    let dir = scratch
    cd $dir
    nu-dir-history enable
    for d in [a b c d] { cd-hooked ($dir | path join $d) }
    press (-1)
    nu-dir-history enable --max-size 3
    assert equal (history-names) [b c d]
    assert equal (nu-dir-history status | get index) 1
    cd-hooked ($dir | path join a)
    assert equal (history-names) [b c a]
}

def --env "test disable restores keybindings and hooks" [] {
    $env.config.keybindings ++= [(user-binding my_f5 none f5)]
    $env.config.hooks.env_change.PWD = [{|before, after| null }]
    let before = $env.config
    nu-dir-history enable
    nu-dir-history enable
    nu-dir-history disable
    assert equal $env.config $before
    assert equal (nu-dir-history status | get enabled) false
}

def --env "test disable removes a PWD hook list that enable created" [] {
    $env.config.hooks.env_change = $env.config.hooks.env_change | reject --optional PWD
    let before = $env.config
    nu-dir-history enable
    nu-dir-history disable
    assert equal $env.config $before
    assert ("PWD" not-in ($env.config.hooks.env_change | columns))
}

def --env "test disable keeps entries the user added after enable" [] {
    $env.config.hooks.env_change.PWD = []
    nu-dir-history enable
    let later = {|before, after| null }
    $env.config.hooks.env_change.PWD ++= [$later]
    $env.config.keybindings ++= [(user-binding later none f5)]
    nu-dir-history disable
    assert equal $env.config.hooks.env_change.PWD [$later]
    assert equal ($env.config.keybindings | ours | length) 0
    assert equal ($env.config.keybindings | where name == later | length) 1
}

def --env "test disable without enable is a no-op" [] {
    let before = $env.config
    nu-dir-history disable
    assert equal $env.config $before
}

# --- navigation -------------------------------------------------------------

def --env "test directory changes are recorded" [] {
    let dir = scratch
    cd $dir
    nu-dir-history enable
    cd-hooked a
    cd-hooked ../b
    cd-hooked ../b
    assert equal (nu-dir-history list) [
        {index: 0, path: $dir, current: false}
        {index: 1, path: ($dir | path join a), current: false}
        {index: 2, path: ($dir | path join b), current: true}
    ]
}

def --env "test back and forward move through the history" [] {
    let dir = scratch
    cd $dir
    nu-dir-history enable
    for d in [a b c] { cd-hooked ($dir | path join $d) }
    press (-1)
    assert equal $env.PWD ($dir | path join b)
    press (-1)
    press (-1)
    assert equal $env.PWD $dir
    press (-1)
    assert equal $env.PWD $dir "stays at the oldest entry"
    press 1
    assert equal $env.PWD ($dir | path join a)
    nu-dir-history forward 2
    assert equal $env.PWD ($dir | path join c)
    nu-dir-history forward
    assert equal $env.PWD ($dir | path join c) "stays at the newest entry"
    nu-dir-history back 3
    assert equal $env.PWD $dir
    assert equal (history-names | length) 4 "navigation records nothing"
}

def --env "test a new directory drops the forward history" [] {
    let dir = scratch
    cd $dir
    nu-dir-history enable
    for d in [a b c] { cd-hooked ($dir | path join $d) }
    press (-1)
    press (-1)
    cd-hooked ($dir | path join d)
    assert equal (history-names) [($dir | path basename) a d]
    press 1
    assert equal $env.PWD ($dir | path join d)
}

def --env "test missing directories are skipped and dropped" [] {
    let dir = scratch
    cd $dir
    nu-dir-history enable
    for d in [a b c d] { cd-hooked ($dir | path join $d) }
    rm --recursive ($dir | path join c) ($dir | path join a)
    press (-1)
    assert equal $env.PWD ($dir | path join b)
    press (-1)
    assert equal $env.PWD $dir
    assert equal (history-names) [($dir | path basename) b d]
    rm --recursive ($dir | path join d)
    press 1
    press 1
    assert equal $env.PWD ($dir | path join b)
    assert equal (history-names) [($dir | path basename) b]
}

def --env "test history keeps at most max size entries" [] {
    let dir = scratch
    cd $dir
    nu-dir-history enable --max-size 2
    for d in [a b c] { cd-hooked ($dir | path join $d) }
    assert equal (history-names) [b c]
    press (-1)
    press (-1)
    assert equal $env.PWD ($dir | path join b)
}

def --env "test reset keeps only the current directory" [] {
    let dir = scratch
    cd $dir
    nu-dir-history enable
    for d in [a b] { cd-hooked ($dir | path join $d) }
    nu-dir-history reset
    assert equal (nu-dir-history list) [{index: 0, path: ($dir | path join b), current: true}]
    press (-1)
    assert equal $env.PWD ($dir | path join b)
}

def --env "test commands need enable" [] {
    assert error { nu-dir-history back }
    assert error { nu-dir-history forward }
    assert error { nu-dir-history list }
    assert error { nu-dir-history reset }
}

def --env "test steps must be positive" [] {
    nu-dir-history enable
    assert error { nu-dir-history back 0 }
    assert error { nu-dir-history forward (-1) }
}

def --env "test disable stops recording" [] {
    let dir = scratch
    cd $dir
    nu-dir-history enable
    nu-dir-history disable
    cd-hooked a
    nu-dir-history enable
    assert equal (history-names) [a]
}

# --- runner -----------------------------------------------------------------

# Each test runs in its own closure, so `$env` changes (including PWD) do not
# leak between tests.
const TESTS = [
    "test key specs parse to modifier and keycode"
    "test invalid key specs are rejected"
    "test generated keybindings are named and run the stored closure"
    "test a null key generates no keybinding"
    "test push appends after the current entry"
    "test push of the current entry changes nothing"
    "test push drops forward entries"
    "test push keeps at most max size entries"
    "test use alone does not change config"
    "test enable installs keybindings and a hook after existing hooks"
    "test enable works without a PWD hook list"
    "test existing hooks keep running"
    "test enable is idempotent and keeps the history"
    "test enable with other keys replaces keybindings"
    "test enable without keybindings"
    "test enable rejects invalid options without changes"
    "test enable with a smaller max size trims the history"
    "test disable restores keybindings and hooks"
    "test disable removes a PWD hook list that enable created"
    "test disable keeps entries the user added after enable"
    "test disable without enable is a no-op"
    "test directory changes are recorded"
    "test back and forward move through the history"
    "test a new directory drops the forward history"
    "test missing directories are skipped and dropped"
    "test history keeps at most max size entries"
    "test reset keeps only the current directory"
    "test commands need enable"
    "test steps must be positive"
    "test disable stops recording"
]

def --env run-test [name: string]: nothing -> any {
    try {
        match $name {
            "test key specs parse to modifier and keycode" => { test key specs parse to modifier and keycode }
            "test invalid key specs are rejected" => { test invalid key specs are rejected }
            "test generated keybindings are named and run the stored closure" => { test generated keybindings are named and run the stored closure }
            "test a null key generates no keybinding" => { test a null key generates no keybinding }
            "test push appends after the current entry" => { test push appends after the current entry }
            "test push of the current entry changes nothing" => { test push of the current entry changes nothing }
            "test push drops forward entries" => { test push drops forward entries }
            "test push keeps at most max size entries" => { test push keeps at most max size entries }
            "test use alone does not change config" => { test use alone does not change config }
            "test enable installs keybindings and a hook after existing hooks" => { test enable installs keybindings and a hook after existing hooks }
            "test enable works without a PWD hook list" => { test enable works without a PWD hook list }
            "test existing hooks keep running" => { test existing hooks keep running }
            "test enable is idempotent and keeps the history" => { test enable is idempotent and keeps the history }
            "test enable with other keys replaces keybindings" => { test enable with other keys replaces keybindings }
            "test enable without keybindings" => { test enable without keybindings }
            "test enable rejects invalid options without changes" => { test enable rejects invalid options without changes }
            "test enable with a smaller max size trims the history" => { test enable with a smaller max size trims the history }
            "test disable restores keybindings and hooks" => { test disable restores keybindings and hooks }
            "test disable removes a PWD hook list that enable created" => { test disable removes a PWD hook list that enable created }
            "test disable keeps entries the user added after enable" => { test disable keeps entries the user added after enable }
            "test disable without enable is a no-op" => { test disable without enable is a no-op }
            "test directory changes are recorded" => { test directory changes are recorded }
            "test back and forward move through the history" => { test back and forward move through the history }
            "test a new directory drops the forward history" => { test a new directory drops the forward history }
            "test missing directories are skipped and dropped" => { test missing directories are skipped and dropped }
            "test history keeps at most max size entries" => { test history keeps at most max size entries }
            "test reset keeps only the current directory" => { test reset keeps only the current directory }
            "test commands need enable" => { test commands need enable }
            "test steps must be positive" => { test steps must be positive }
            "test disable stops recording" => { test disable stops recording }
            _ => (error make {msg: $"no such test: ($name)"})
        }
        null
    } catch {|err| $err.msg }
}

def main [] {
    let root = mktemp --directory --tmpdir nu-dir-history-test.XXXXXX
    let results = $TESTS | each {|name|
        {name: $name, error: (do { $env.__TEST_ROOT = $root; run-test $name })}
    }
    rm --recursive $root
    for r in $results {
        if $r.error == null {
            print $"ok    ($r.name)"
        } else {
            print $"FAIL  ($r.name): ($r.error)"
        }
    }
    let failed = $results | where error != null | length
    print $"\n($results | length) tests, ($failed) failed"
    if $failed > 0 { exit 1 }
}

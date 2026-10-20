# Minimal config to try nu-dir-history without any other customization:
#
#   nu --config examples/minimal-config.nu
#
# In your own config.nu, replace the path below with where you cloned the repo,
# or put the clone's parent directory in $env.NU_LIB_DIRS and `use nu-dir-history`.

$env.config.show_banner = false

use ../nu-dir-history
# Ctrl+Shift+Left / Ctrl+Shift+Right go back / forward.
# Use `nu-dir-history enable --back-key alt+b --forward-key alt+f` for other keys.
nu-dir-history enable

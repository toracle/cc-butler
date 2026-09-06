# Per-fleet machine configuration for the matrix-bridge send-side scripts
# (post-to-lounge.sh).  Sourced automatically if present next to the script;
# MATRIX_BRIDGE_CONFIG=<path> overrides which file gets sourced.  Every value
# here is also settable directly as an env var, which always wins over
# whatever this file sets (`: "${VAR:=default}"` only fills what's unset).
#
# Same externalization pattern matrix-bridge.el uses (PR #175): each fleet
# edits its own copy of the per-machine values instead of the script
# hardcoding one fleet's paths.  Unlike matrix-bridge-self-user-id (which
# defaults to nil and fails loudly, because a wrong default there silently
# mis-routes), the values below default to x600's live paths -- a wrong path
# here just fails loudly on `cat: no such file`, so shipping x600's real
# values costs nothing and keeps x600 working with zero config.  A second
# fleet edits the values below (or sets the env vars) to its own paths.

: "${MATRIX_BRIDGE_CONDUIT_DIR:=/home/toracle/services/conduit}"
: "${MATRIX_BRIDGE_HOMESERVER:=http://localhost:8008}"
: "${MATRIX_BRIDGE_SELF_TOKEN_FILE:=$MATRIX_BRIDGE_CONDUIT_DIR/butler-x600.token}"
: "${MATRIX_BRIDGE_ROOM_ID_FILE:=$MATRIX_BRIDGE_CONDUIT_DIR/lounge-room-id.txt}"
: "${MATRIX_BRIDGE_HUMAN_MXID:=@jeongsoo:warmblood-lounge}"

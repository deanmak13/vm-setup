# Strict allowlist grammar check (called by docker-user-firewall.sh validate_allowlist).
# vars: role, trust (space list), pass (space list). Reads the allowlist twice (roles, then lines).
BEGIN { n = split(trust, a, " "); for (i = 1; i <= n; i++) T[a[i]] = 1
        n = split(pass, a, " ");  for (i = 1; i <= n; i++) P[a[i]] = 1 }
{ sub(/#.*/, "") }
NF == 0 { next }
NR == FNR { if ($2 == "role" && $1 == "all" && NF == 3 && $3 ~ /^[a-z][a-z0-9-]*$/) R[$3] = 1; next }
function bad(m) { print "invalid allowlist line " FNR ": " m > "/dev/stderr"; err = 1 }
{
    if ($2 == "role") { if (NF != 3 || $1 != "all" || $3 !~ /^[a-z][a-z0-9-]*$/) bad($0); next }
    if ($1 != "all" && !($1 in R)) { bad("undeclared role: " $0); next }
    if ($2 == "trust-iface") { if (NF != 3 || !($3 in T)) bad("trust-iface not in the explicit set: " $0); next }
    if ($2 == "passthrough-iface") { if (NF != 3 || !($3 in P)) bad("passthrough-iface not allowed: " $0); next }
    if ($2 == "allow") { if (NF != 4 || ($3 != "tcp" && $3 != "udp") || $4 !~ /^[0-9]+$/ || $4 < 1 || $4 > 65535) bad($0); next }
    bad("unknown kind: " $0)
}
END { if (!(role in R)) { print "role not declared in allowlist: " role > "/dev/stderr"; err = 1 }
      exit err }

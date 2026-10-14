# Prints the value fields of allowlist lines of KIND for ROLE (or `all`).
{ sub(/#.*/, "") } NF >= 3 && ($1 == "all" || $1 == role) && $2 == kind { $1 = $2 = ""; sub(/^ +/, ""); print }

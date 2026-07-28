#!/bin/bash

set -e

API_URL="https://pokeapi.co/api/v2/pokemon?limit=649"
OUTPUT_FILE_PATH="./data/pokemon.json"

mkdir -p "./data"

curl -s "$API_URL" |
tr '{' '\n' |
sed -n 's/.*"name":"\([^"]*\)".*/\1/p' |
awk '
BEGIN {
    print "["
}
{
    name = toupper(substr($0, 1, 1)) tolower(substr($0, 2))

    printf "%s  {\"id\": %d, \"name\": \"%s\"}", (NR==1?"":",\n"), NR, name
}
END {
    print "\n]"
}
' > "$OUTPUT_FILE_PATH"

echo "Successfully generated $OUTPUT_FILE_PATH"
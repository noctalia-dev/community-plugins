#!/bin/bash

set -e

POKEMON_DATA_FILE_PATH="./data/pokemon.json"
SPRITES_DIRECTORY="./assets/sprites"
SPRITES_URL="https://img.pokemondb.net/sprites/black-white/normal"

mkdir -p "$SPRITES_DIRECTORY"

if [ ! -f "$POKEMON_DATA_FILE_PATH" ]; then
    echo "Error: '$POKEMON_DATA_FILE_PATH' was not found."

    exit 1
fi

echo "Downloading Pokémon sprites..."

while read -r line; do
    if [[ "$line" =~ \"id\":[[:space:]]*([0-9]+) ]]; then
        pokemon_id="${BASH_REMATCH[1]}"
    fi

    if [[ "$line" =~ \"name\":[[:space:]]*\"([^\"]+)\" ]]; then
        pokemon_name="${BASH_REMATCH[1],,}"

        sprite_url="$SPRITES_URL/${pokemon_name}.png"
        output_path="$SPRITES_DIRECTORY/${pokemon_id}.png"

        echo "Downloading $pokemon_name (ID: $pokemon_id)"

        curl -s -o "$output_path" "$sprite_url"
    fi
done < "$POKEMON_DATA_FILE_PATH"

echo "Successfully downloaded all sprites to $SPRITES_DIRECTORY."
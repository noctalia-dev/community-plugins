# Whos That Pokémon

A simple and fully offline Pokémon mini-game plugin for Noctalia shell.

The game currently supports only English Pokémon names and includes Pokémon from Generations I through V.

## Plugin

| Field | Value |
| --- | --- |
| ID | `devpotatoes/whosthatpokemon` |
| Entries | Launcher provider: `launcher`; panel: `panel` |
| Launcher Prefix | `/wtp` |

## Usage

Open the Noctalia launcher and type `/wtp` then start the mini-game !

## IPC

```sh
noctalia msg panel-toggle devpotatoes/whosthatpokemon:panel
```

## Notes

The `fetchPokemonList.sh` and `fetchPokemonSprites.sh` scripts are only automation tools intended to help developers prepare the required Pokémon data and assets.
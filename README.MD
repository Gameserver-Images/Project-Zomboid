# Project Zomboid dedicated server container

A Docker image for a Project Zomboid dedicated server, configured entirely through environment variables.

* The image holds no game. The container installs it from Steam on its first start and updates it on every restart.
* One image serves every game version Steam offers: the stable game, the beta, older versions and Build 41.
* Every variable it reads is listed with its description for each game build at **https://gameserver-images.github.io/Project-Zomboid/**.

## Quick start

`docker-compose.yml`:

```yaml
services:
  ProjectZomboidDedicatedServer:
    image: ghcr.io/gameserver-images/project-zomboid:1
    restart: unless-stopped
    stop_grace_period: 120s
    env_file:
      - .env
    ports:
      - "16261:16261/udp"
      - "16262:16262/udp"
    volumes:
      - data:/home/steam/Zomboid
      - game:/home/steam/pz-dedicated

volumes:
  data:
  game:
```

`.env`:

```bash
ADMINPASSWORD=change-me
INI_Password=change-me-too
INI_PublicName=My server
INI_Public=false
SANDBOX_ZombieLore__Transmission=3
```

Then run `docker compose up -d`. The first start downloads the game (about 7 GB) into the `game` volume, which also holds workshop mods, and creates the admin account from `ADMINPASSWORD`, which that start requires. The server is up when the container shows as `healthy`.

The container runs as uid 1000. Named volumes work as they are. A bind-mounted folder needs `chown -R 1000:1000 <folder>`.

On Windows with WSL2 in Docker Desktop the server starts much slower, which hurts with many mods (15 to 40 minutes). Use Linux or a Linux VM if you can.

## Configuration

There are three kinds of variables. The [env var site](https://gameserver-images.github.io/Project-Zomboid/) lists every one for each game build. `docker exec <container> list-env [filter]` lists them for your own server, with their current values and your mods' settings.

| Variable | Sets | Example |
|---|---|---|
| `INI_<Key>` | `Key` in `Zomboid/Server/pzserver.ini` | `INI_MaxPlayers=16` |
| `SANDBOX_<Group>__<Key>` | A setting in `pzserver_SandboxVars.lua`; `__` separates nested tables | `SANDBOX_ZombieLore__Mortality=7` |
| Image settings | Game version, admin account, workshop items, memory, ports and more | `MEMORY=8g` |

How they apply:

* Variables are written on every start. One you remove leaves its last value in the file; set it empty to clear it.
* Once the server has written its files (from the second start), names and values are checked against them. A name that matches no setting, or a value of the wrong type such as `INI_Public=yes`, isn't written, and the log warns about it. `CONFIG_STRICT=true` refuses to start instead. The log also warns about variables the image doesn't read at all.
* Sandbox settings apply from the second start, because the server writes its SandboxVars file on the first. `SERVERPRESET` creates that file from one of the game's presets before the first start.
* `INI_<Key>_FILE` and `ADMINPASSWORD_FILE` read the value from a file, for Docker secrets. `list-env` shows passwords and tokens as `(set)`.
* On/off image settings accept `1`, `true`, `yes`, `y` or `on`.

## Game version

`GAME_BRANCH` picks the game from the "Betas" list in the game's properties in Steam: `public` (the stable game, default), `unstable` (the beta, while one is open), an older version such as `42.19`, or `legacy41` (Build 41). Changing it switches the game on the next start, which checks every file and takes a while. Build 41 and Build 42 worlds aren't compatible, so give each its own data volume.

Every restart brings the game up to date, which matters because updated clients can't join an older server. `GAME_UPDATE=false` starts the installed game without asking Steam, to hold a version.

## Mods and maps

* `WORKSHOP_IDS`: workshop item and collection IDs separated by `;`. Collections are expanded into their items; private or unlisted ones need `STEAM_API_KEY`. The server downloads the items while it starts. Items that are removed, hidden or private on the workshop are left out with a warning, since the server can't download them and would stop with an error.
* `INI_Mods`: the mod IDs to enable, separated by `;`. On Build 42 each one starts with a backslash (`INI_Mods=\ModOne;\ModTwo`); write a single backslash in the env file.

Maps from enabled mods are added to the `Map=` line automatically, before the vanilla map, with their spawn points. Since downloads happen while the server starts, a new map is added on the start after the one that downloaded it. Taking a map mod out of `INI_Mods` removes its maps again.

`docker exec <container> list-mods > mods.json` describes your workshop items and every mod in them: requirements, load order hints, maps and sandbox options. Load that file on the [mods page](https://gameserver-images.github.io/Project-Zomboid/mods.html) to pick and order mods and set their sandbox options, then copy the `.env` lines it writes. The log also warns at startup about enabled mods that are missing, lack a required mod, load in the wrong order or conflict.

## Running the server

* `docker stop` (or stopping it in Portainer) makes the server save the world and quit. `stop_grace_period: 120s` gives it time for that.
* `docker exec <container> console <command>` sends a command to the server console, for example `console save` or `console servermsg "Restart in 5 minutes"`. The reply shows up in the container log.
* For remote administration, set `INI_RCONPassword`, publish `27015/tcp` and use any Source RCON client.
* The server makes its own backups: see `INI_BackupsCount`, `INI_BackupsOnStart`, `INI_BackupsPeriod` and `INI_BackupsOnVersionChange`. The last one is worth turning on, since any restart can bring a new game version.
* `TZ`, for example `Europe/Copenhagen`, sets the time zone of the server's log files.

## Ports

| Port | Use | Variable |
|---|---|---|
| 16261/udp | Game | `PORT` |
| 16262/udp | Game, second port | `UDPPORT` |
| 27015/tcp | RCON, only if you use it | `INI_RCONPort` |
| 8766-8767/udp | Steam, Build 41 only | `STEAMPORT1`, `STEAMPORT2` |

Forward the UDP ports in your firewall or router. If you change a port variable, change the published port to match. The log prints the ports on every start, and the [wiki](https://pzwiki.net/wiki/Dedicated_server) has more on them.

## Image versions

Images are published to `ghcr.io/gameserver-images/project-zomboid` with these tags:

* `1`: the newest 1.x version. It gets fixes and new features, but nothing that needs you to change your setup. Use this one.
* `1.2` or `1.2.3`: one minor version with its fixes, or one exact version.
* `latest`: the newest version, including new major versions, which can need changes to your setup.

The [releases page](https://github.com/Gameserver-Images/Project-Zomboid/releases) says what changed in each version and what to change for a new major one.

CI boots every new version on every Steam branch and only publishes it once it runs on the stable game. It also checks Steam every hour and boots the current version on each new game build.

## Building the image

```bash
docker build --build-arg EXTRA_LOCALES="es_ES.UTF-8 de_DE.UTF-8" -t pz-server .
```

Only `en_US.UTF-8` is installed by default. `EXTRA_LOCALES` adds more, and `LANG` picks the one the server uses.

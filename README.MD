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
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
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

Every restart brings the game up to date, which matters because updated clients can't join an older server. `GAME_UPDATE=false` starts the installed game without updating it, to hold a version; new workshop items are still downloaded.

## Mods and maps

* `WORKSHOP_IDS`: workshop item and collection IDs separated by `;`. Collections are expanded into their items; private or unlisted ones need `STEAM_API_KEY`. Items that aren't downloaded yet are downloaded with SteamCMD before the server starts, and the server keeps them up to date. Items that are removed, hidden or private on the workshop are left out with a warning, since the server can't download them and would stop with an error; one it already downloaded stays, without updates.
* `INI_Mods`: the mod IDs to enable, separated by `;`. Build 42 writes them with a backslash in front (`INI_Mods=\ModOne;\ModTwo`; write a single backslash in the env file), but plain IDs work too, and Build 41 needs them plain. The server also loads the mods they require, before them, whether or not they are listed.
* `MOD_UPDATE_CHECK`: how often the server checks its workshop items for updates, such as `15m` (`s`, `m` or `h`; off by default). Players can't join while the server has an older version of an item than the workshop ("Workshop item version is different than the server's"), and the server only updates items when it starts. So when an item has an update, the server warns the players online 5 minutes ahead (or the interval, when that is shorter) and quits, saving the world, to download it as it starts again; with nobody online it quits at once. The container exits with code 0 for that, so it needs a restart policy that starts it again, such as `restart: unless-stopped` (`on-failure` doesn't). The check covers the items in WorkshopItems when the server started, and `console checkModsNeedUpdate` restarts the server the same way while it is on.

Maps of the mods the server loads are added to the `Map=` line automatically, with their spawn regions, from the first start on, so a new world has them from the beginning. When `Zomboid/Server/pzserver_spawnregions.lua` is missing, the image first writes the game's default file with the vanilla towns, on Build 41 too, where the game only writes it for a server without an INI. `INI_Map` decides the order: its maps keep their order, maps of mods the server loads are added before the vanilla map, and maps of mods it doesn't load are taken out. Taking a map mod out of `INI_Mods` removes its maps again. An item SteamCMD can't download, such as a large one it times out on, is downloaded by the server while it starts, and its maps are added on the start after; until every item is downloaded, maps are only added.

Every start that can read the game version from the game files logs the `Map=` line (`Config: Map is ...`) and warns about two problems with maps:

* A zone the game fails on, such as a water zone drawn as a polygon. The game reads the maps from the last in `Map=` to the first and stops loading map zones at that zone on every start, so the maps before its map in `Map=` lose their car spawns, animals, basements, water and the like. Remove that map's mod, report it to the map's author, or put the map first in `Map=` (set `INI_Map` to the whole list in your order) so it only loses its own zones. When several maps have such a zone, the warning names them all, since fixing one only moves the stop to the next.
* Maps of different workshop items that share cells. Where both have something on a square, the one earlier in `Map=` wins. If the other one should, change the order with `INI_Map`.

`docker exec <container> list-mods > mods.json` describes your workshop items and every mod in them: requirements, load order hints, maps and sandbox options. Load that file on the [mods page](https://gameserver-images.github.io/Project-Zomboid/mods.html) to pick and order mods and set their sandbox options, then copy the `.env` lines it writes. The page lists the server settings your mods' workshop pages ask for as well, such as `DoLuaChecksum=false`, with the server's current value and the `INI_` line that sets it. The log also warns at startup about enabled mods the server can't find or won't load, saying why, and about mods that load in the wrong order or conflict. Players whose ZombieBuddy agent moves `ZombieBuddy` to the front of their mods are kicked for the Lua checksum unless the server loads it first too, so the log warns when it doesn't and the mods page's Sort puts it first.

With many mods the game can need more inotify watches than the host allows (`fs.inotify.max_user_watches`, a limit shared by every program of the same user on the host), and the server then stops while it starts. Every start checks this. When the game would need more than half of the limit, the log says so and the game's file watcher is off for that start; it only reloads game and mod files that change while the server runs. It is also off for a start that can't count the mod folders, because a workshop item couldn't be downloaded before it or the game version couldn't be read from the game files. To keep it on, raise the limit on the Docker host (not in the container):

```bash
sudo sysctl -w fs.inotify.max_user_watches=524288
echo 'fs.inotify.max_user_watches=524288' | sudo tee /etc/sysctl.d/90-inotify.conf
```

On a NAS that resets `/etc` on a reboot or update (Synology, Unraid), run the first command from a task that runs at boot instead. `GAME_FILE_WATCHER=true` keeps the watcher on and `false` keeps it off.

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

Unless you set `INI_UPnP`, the image sets it to `false`, since the game's UPnP can't reach your router from Docker's network and only slows down the start; `INI_UPnP=true` only makes sense with `network_mode: host`.

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

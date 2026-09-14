# Resolume Scheduler (macOS)

Helper app per Mac ispirata a [jorisdejong/Scheduler](https://github.com/jorisdejong/Scheduler).

## Orologio

| Modalità | Sorgente | Nome clip |
|---|---|---|
| **World Clock** | orologio di sistema | `HHMM` (es. `1430`) |
| **LTC** | timecode lineare da **input audio** (libltc) | `00:01:01.12` (HH:MM:SS.FF) |

### Impostazioni LTC

- Frame rate: **24 / 25 / 30** fps  
- Input audio: device CoreAudio a scelta  
- **Canale** LTC sull’input (1…N)  
- OSC host + **porta** verso Resolume (default `127.0.0.1:7000`)

## Trigger

| Modalità | OSC |
|---|---|
| **Clip** | `/composition/layers/L/clips/C/connect` |
| **Colonna** | `/composition/columns/C/connect` |
| **Colonna gruppo** | `/composition/groups/G/columns/C/connect` |

## Requisiti

- Composition Resolume **salvata**
- OSC Input abilitato sulla porta configurata
- Per LTC: segnale LTC sull’input audio + permesso microfono all’app

## Build

```bash
cd ~/Downloads/ResolumeScheduler
./build-app.sh
```

LTC via [libltc](https://x42.github.io/libltc/) (LGPL-3.0), sources in `Vendor/libltc`.

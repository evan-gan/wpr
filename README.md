# wpr

setup shaders as your wallpaper & generate new ones on a cron

## install

```sh
brew tap maxwofford/wpr
# brew trust maxwofford/wpr/wpr
brew install wpr
```

## shaders

there are a couple pre-installed. build your own or install some of these.

here's a list i made:

<table>
  <tr><td align="center"><a href="https://github.com/maxwofford/wpr-wells"><img src="https://cdn.hackclub.com/01a0b1f5-4c50-7989-81f6-a9f8f11c2edf/wells.png" width="260" alt="wells"><br>maxwofford/wells</a></td><td align="center"><a href="https://github.com/maxwofford/wpr-tunic"><img src="https://cdn.hackclub.com/01a0b1f5-4e99-7e6e-b944-375a2cf5cc4d/tunic.png" width="260" alt="tunic"><br>maxwofford/tunic</a></td><td align="center"><a href="https://github.com/maxwofford/wpr-spectra"><img src="https://cdn.hackclub.com/01a0b1f5-507d-7763-93db-c7de3f4d1e33/spectra.png" width="260" alt="spectra"><br>maxwofford/spectra</a></td></tr>
</table>

here are some i didn't make, but packaged up (credits in each repo)

<table>
  <tr><td align="center"><a href="https://github.com/maxwofford/wpr-melange"><img src="https://cdn.hackclub.com/01a0b1f5-52d8-7545-b7a4-5064c9a47552/melange.png" width="260" alt="melange"><br>maxwofford/melange</a></td><td align="center"><a href="https://github.com/maxwofford/wpr-monterey"><img src="https://cdn.hackclub.com/01a0b1f5-54e1-7891-955a-70120c15e031/monterey.png" width="260" alt="monterey"><br>maxwofford/monterey</a></td><td align="center"><a href="https://github.com/maxwofford/wpr-cosmos"><img src="https://cdn.hackclub.com/01a0b1f5-56ae-7ff6-a13d-0f0829735c19/cosmos.png" width="260" alt="cosmos"><br>maxwofford/cosmos</a></td></tr>
  <tr><td align="center"><a href="https://github.com/maxwofford/wpr-aurora"><img src="https://cdn.hackclub.com/01a0b1f5-589a-74d1-ba98-8b34c7b2bc76/aurora.png" width="260" alt="aurora"><br>maxwofford/aurora</a></td></tr>
</table>

## usage

```sh
# the basics...
wpr next                  # set the next wallpaper in the queue
wpr timer install         # automatically set it every 30 min
wpr next --no-all-spaces  # only change the current Space (default: every Space, see all_spaces in config)

# want some shaders? install them kinda like brew
wpr install maxwofford/spectra
wpr install maxwofford/wpr-spectra
wpr install https://github.com/maxwofford/wpr-spectra
wpr install git@github.com:maxwofford/wpr-spectra.git
# even install them locally so you can modify them
git clone git@github.com:maxwofford/wpr-spectra.git &&
wpr install ./wpr-spectra

# now use it!
wpr gen spectra
# like it? add it to the rotation
wpr enable spectra
wpr disable wells

# check what else is installed
wpr sources
```

## config

`~/.config/wpr/config.toml`

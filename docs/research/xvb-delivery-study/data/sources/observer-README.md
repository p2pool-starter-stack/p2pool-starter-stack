# P2Pool Observer

This repository contains the running code to produce statistics and historical archives of [Monero P2Pool](https://github.com/SChernykh/p2pool) decentralized pool.

## Reporting issues

You can give feedback or report / discuss issues on:
* [The issue tracker on git.gammaspectra.live/P2Pool/observer](https://git.gammaspectra.live/P2Pool/observer/issues?state=open)
* Via IRC on [#p2pool-observer@libera.chat](ircs://irc.libera.chat/#p2pool-observer), or via [Matrix](https://matrix.to/#/#p2pool-observer:monero.social)
* Any of the relevant rooms for the specific observer instances listed below.

## Maintainer-run Observer Instances

| Host                                                         | Onion Address                                                                                                                            | IRC Channel                                                                                                                                                         | Notes                                                                        |
|--------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------|
| [P2Pool.Observer](https://p2pool.observer/)                  | [p2pool2giz2r5cpqicajwoazjcxkfujxswtk3jolfk2ubilhrkqam2id.onion](http://p2pool2giz2r5cpqicajwoazjcxkfujxswtk3jolfk2ubilhrkqam2id.onion/) | [#p2pool-log](ircs://irc.libera.chat/#p2pool-log) or [Matrix](https://matrix.to/#/#p2pool-log:monero.social)                                                        | Tracking up-to-date [Main P2Pool](https://p2pool.io/) on Mainnet             | 
| [MINI.P2Pool.Observer](https://mini.p2pool.observer/)        | [p2pmin25k4ei5bp3l6bpyoap6ogevrc35c3hcfue7zfetjpbhhshxdqd.onion](http://p2pmin25k4ei5bp3l6bpyoap6ogevrc35c3hcfue7zfetjpbhhshxdqd.onion/) | [#p2pool-mini](ircs://irc.libera.chat/#p2pool-mini) or [Matrix](https://matrix.to/#/#p2pool-mini:libera.chat) [[2]](https://matrix.to/#/#p2pool-mini:monero.social) | Tracking up-to-date [Mini P2Pool](https://p2pool.io/mini/) on Mainnet        |
| [NANO.P2Pool.Observer](https://nano.p2pool.observer/)        | [p2pnanphwyo2smf3khhjjkmfxll7h2ptmj4iwrbjklsk2wx66m5m7oad.onion](http://p2pnanphwyo2smf3khhjjkmfxll7h2ptmj4iwrbjklsk2wx66m5m7oad.onion/) | [#p2pool-mini](ircs://irc.libera.chat/#p2pool-mini) or [Matrix](https://matrix.to/#/#p2pool-mini:libera.chat) [[2]](https://matrix.to/#/#p2pool-mini:monero.social) | Tracking up-to-date [Nano P2Pool](https://p2pool.io/nano/) on Mainnet        |
| [OLD.P2Pool.Observer](https://old.p2pool.observer/)          | [temp2p7m2ddclcsqx2mrbqrmo7ccixpiu5s2cz2c6erxi2lppptdvxqd.onion](http://temp2p7m2ddclcsqx2mrbqrmo7ccixpiu5s2cz2c6erxi2lppptdvxqd.onion/) | [#p2pool-log](ircs://irc.libera.chat/#p2pool-log) or [Matrix](https://matrix.to/#/#p2pool-log:monero.social)                                                        | Tracking old fork pre-v3.0 [Main P2Pool](https://p2pool.io/) on Mainnet      |
| [OLD-MINI.P2Pool.Observer](https://old-mini.p2pool.observer/) | [temp2pbud6av2jx3lh3yovrj4mjjy2k4p5rxydviosp356ndzs4nd6yd.onion](http://temp2pbud6av2jx3lh3yovrj4mjjy2k4p5rxydviosp356ndzs4nd6yd.onion/) | [#p2pool-mini](ircs://irc.libera.chat/#p2pool-mini) or [Matrix](https://matrix.to/#/#p2pool-mini:libera.chat) [[2]](https://matrix.to/#/#p2pool-mini:monero.social) | Tracking old fork pre-v3.0 [Mini P2Pool](https://p2pool.io/mini/) on Mainnet |

## Donations
This project is provided for everyone to use, for free, as a hobby project. Any support is appreciated.

Donate to support this project, its development, and running the Observer Instances on [4AeEwC2Uik2Zv4uooAUWjQb2ZvcLDBmLXN4rzSn3wjBoY8EKfNkSUqeg5PxcnWTwB1b2V39PDwU9gaNE5SnxSQPYQyoQtr7](monero:4AeEwC2Uik2Zv4uooAUWjQb2ZvcLDBmLXN4rzSn3wjBoY8EKfNkSUqeg5PxcnWTwB1b2V39PDwU9gaNE5SnxSQPYQyoQtr7?tx_description=P2Pool.Observer)

You can also use the OpenAlias `p2pool.observer` directly on the GUI.

## Operational instructions

A docker compose setup is provided and documented.

If desired each tool can be run individually, but that is left to the user to configure, refer to Docker setup as reference.  

### Requirements
* `docker compose` or similar
* `git` installed
* Disk space for new incoming historic data. Assume a few tens of MiB per day
* A monerod non-pruned node running in unrestricted mode preferably, but can work with restricted mode. 
* Enough RAM to fit state and incoming queries. It can run with lower with adjustment of settings, but 8 GiB per instance should be fine.

### Initial setup
```bash
$ git clone https://git.gammaspectra.live/P2Pool/observer.git test-instance
$ cd test-instance
$ cp .env.example .env
```
Edit `.env` via your preferred editor, specifically around the monerod host options and generate keys for the Tor hidden service.

If you want to make changes to additional docker compose settings, do not edit `docker-compose.yml`. Instead, create `docker-compose.override.yml` and place new settings there. See [Multiple Compose files documentation](https://docs.docker.com/compose/extends/#multiple-compose-files).

### Update / Apply new settings
Within the instance folder, run this command
```bash
$ git checkout -- '*/default.pgo'; \
git pull && \
docker compose build --pull && \
docker compose up -d && \
docker compose restart tor site
```
`docker compose restart tor` is necessary due to the tor server not refreshing DNS of the containers.

It is recommended to run `docker system prune` regularly or after update to cleanup no longer used images.

### Development notes

Requires using CGO when running the main modes where RandomX hashes are used, but can be used with `CGO_ENABLED=0` specifically as a library.

You can install the RandomX dependency via this command:
```bash
$ git clone --depth 1 --branch master https://github.com/tevador/RandomX.git /tmp/RandomX && cd /tmp/RandomX && \
    mkdir build && cd build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -D CMAKE_INSTALL_PREFIX:PATH=/usr && \
    make -j$(nproc) && \
    sudo make install && \
    cd ../ && \
    rm -rf /tmp/RandomX
```


To generate web templates, run this command:
```bash
$ go run github.com/valyala/quicktemplate/qtc@v1.8.0
```
docker run --rm -it \
  -v /tools/certs:/acme.sh \
  -e DEDYN_TOKEN=your_token_here \
  neilpang/acme.sh --issue \
    --server letsencrypt \
    --dns dns_desec \
    --challenge-alias klarwasser.dedyn.io \
    -d kuehl.one \
    -d adguard.kuehl.one \
    -d paperless.kuehl.one \
    -d homeassistant.kuehl.one \

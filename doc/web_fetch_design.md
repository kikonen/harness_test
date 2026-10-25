# web.fetch: the harness' second network surface, and the guards around it

Issue #33 asked for web search. The measurement below showed the keyless search
recipe the issue quoted returns nothing here, so #33 is being delivered in two
PRs: `web.fetch` first (this doc), `web.search` as its own issue with a pluggable
backend. What lives where:

- `lib/web_fetcher.rb` - the transport and EVERY fetch rule (scheme, address
  guard, redirect re-validation, byte cap). No rule here is grantable.
- `lib/address_guard.rb` - the two tiers of refused addresses.
- `lib/web_host_allowlist.rb` - the persisted host grants (exact host only).
- `lib/tools/web_fetch_tool.rb` - the USER side: the consent dialog, what the
  user sees before anything is sent, the output budget.

The transport numbers below are reproducible from a fresh clone with
`ruby analysis/33/repro.rb` (measured on Windows, Ruby 4.0.7). The search-engine
response codes in the next section were measured by hand while designing #33 and
are NOT in that repro: they describe a third party's bot wall, which changes, so
treat them as the reason for the split rather than as a fact to re-verify.

---

## Why search could not ride along (the #33 split)

The issue's own recipe is a keyless `duckduckgo.com`-style curl. Measured by hand
while designing #33 (a third party's bot wall, so not reproducible from here):

- `duckduckgo.com/?q=...&format=json` - HTTP **202** with an Instant-Answer
  widget (one RelatedTopic), not a results list.
- `html.duckduckgo.com` and `lite.duckduckgo.com` - HTTP **202** with an
  `anomaly-modal` body and **0 result links**, even with a browser User-Agent.
- `en.wikipedia.org/w/api.php` - HTTP **200** with real JSON.

So a "search" backend built on the recipe in #33 would return a page that
contains no results, and a keyless search engine that answers a scripted client
is not something this harness can promise. `web.search` is therefore a separate
issue with a pluggable backend (a user-supplied endpoint or key), not a variant
of this fetch. `web.fetch` is the part that works with no key and no vendor.

## Consent is a separate axis from the guards

Two independent questions decide whether a fetch happens, and a grant can only
answer the first:

1. **May this host be ASKED for?** - the user's decision, persisted per host.
2. **What may be done to whatever it points at?** - scheme, addresses, redirects
   and size: always enforced, never configurable by the model or by a grant.

The shell postures are deliberately NOT reused (issue #221 is about SHELL
commands). `/yolo` off-loading consent for `git status` says nothing about
fetching a URL, so an ungranted host reaches the dialog in EVERY posture, with
no "always allow in this posture" shortcut. A host grant is saved only through
the dialog's explicit "Always allow '<host>'" option.

`web_fetch_allow_private` is a config key - a user-side posture like `yolo` -
and the model has no argument that reaches it. It lifts the PRIVATE tier only.

## The address guard has two tiers, because the opt-in must not be a pass

`IPAddr#private?` alone is not a guard on this Ruby (measured, Ruby 4.0.7):

| address | `IPAddr#private?` |
|---|---|
| `127.0.0.1`, `::1`, `::` | **false** |
| `100.64.0.1` (CGNAT) | false |
| `169.254.169.254` (cloud metadata) | false |

so both tiers are listed as explicit ranges in `AddressGuard`:

- `BLOCKED_ALWAYS` - link-local (`169.254.0.0/16`, which holds the metadata
  endpoint), multicast, `0.0.0.0` and `::`. No opt-in lifts these: a harness
  fetch has no legitimate reason to reach them, and lifting loopback for a
  localhost dev server must not also open the metadata range.
- `PRIVATE_NETS` - loopback, RFC1918, CGNAT, IPv6 unique-local. Refused by
  default; lifted only by `web_fetch_allow_private: true` (a localhost dev
  server, an intranet wiki).

An address that does not parse is refused: the guard cannot prove it is safe.
`::ffff:127.0.0.1` is normalized to its IPv4 form first, or it would slip past
every v4 range.

## Resolving once IS the guard (measured)

Checking the resolved address and then letting `Net::HTTP` resolve again is the
classic rebinding pass around any address guard. Measured: a request built with
`Net::HTTP.new("example.invalid")` and `http.ipaddr = "127.0.0.1"` connects to
localhost while sending `Host: example.invalid`. So `#attempt` connects to the
address `#resolve_and_guard` already checked, and EVERY address is checked: a
host with one public and one private record is refused outright, not reached
through the public one. Trying the checked addresses in turn is the dual-stack
case (an AAAA record this machine cannot reach), not a way past the guard.

Redirects are re-validated hop by hop, up to `MAX_REDIRECTS = 5`, with a visited
set (a loop stops rather than spinning). A `Location` that is relative, absolute,
or not a URL at all (`javascript:`, `file:`) lands on a refusal, not a crash.

## Two measured transport facts that shaped the reader

**The byte cap must stop the transfer, not the text.** Reading a 4 MB chunked
body with NO cap pulls all 4 000 000 bytes. With a 50 KB cap the client stops at
the first chunk that crosses it and the server keeps pushing until it notices the
reset (it had written a few hundred KB by then - the exact number is a race). The
connection really ends, so a lying `Content-Length` costs neither bandwidth nor
RAM. The cap is raised inside the `read_body` block (`BodyTooLarge`), which is
what makes it a download stop.

**A redirect body must never be read.** `Net::HTTP` auto-reads a redirect body
when the response is taken without a block. Taking the body of a 302 that carries
8 MB reads all 8 000 000 bytes - and with a cap in the read, that body reaches
the cap and fails the WHOLE fetch, including the good hop after it. Skipping the
read for a redirect reads 0 bytes and the chain still resolves. Only a redirect's
`Location` is ever used, so `unless redirect?(res)` wraps the read.

The block form of `#request` also does not decompress, so `#decode` owns
content-encoding: `identity` is asked for but a server may answer gzip anyway
(measured: a server asked for identity still sent `content-encoding: gzip`), and
a body that claims gzip and is not stays as the raw bytes the server sent.
`TextNormalizer` runs at this read boundary, so a non-UTF-8 body cannot break the
session save.

## A blocked IP literal is refused BEFORE the user is asked

`WebFetcher#literal_block` decides from the URL STRING ALONE, so the tool refuses
`http://127.0.0.1:8080/` without a dialog: a consent prompt about an address the
guard already decided on is noise, and a grant could not change the answer.

The ordering rule it exists to protect: **a resolve is itself a network side
effect**, so it must not happen before consent. A host NAME is therefore left to
the resolve path (consent first, DNS second) - `#literal_block` returns nil for
it. `analysis/33/repro.rb` asserts the "no lookup" half of this.

## Host grants are EXACT hosts, never suffixes

`.harness/allowed_hosts.yml`, matching on the normalized host only
(`TextNormalizer` + strip + downcase + a leading scheme and a trailing slash
removed, on BOTH the save and the lookup side, so `Example.COM ` and
`example.com.` cannot dodge a grant or miss one).

The shell allowlist composes by prefix (`git` -> `git log` -> `git log --oneline`)
because a command is a token tree. A hostname does not compose that way: the
tempting "subdomain of" rule is exactly how a granted domain gets abused, so a
grant for `example.com` does NOT cover `evil.example.com` or
`example.com.attacker.tld`, and `#candidates` offers nothing but the host itself.
Several hosts means several grants.

A grant says only whether a host may be asked for. `spec/lib/tools/web_fetch_tool_spec.rb`
keeps that separation honest: an Always-allow on a host name that resolves to
loopback saves the grant AND still refuses the address.

## Output budget

A fetched page is model-supplied-size text going straight into the context
window, so the body is truncated to a line limit with the house notice (the same
rule as `run.command` output): default 200 lines, hard cap 2000. The byte cap in
the fetcher is what bounds the download itself; the line limit is what bounds the
conversation. A failure returns the fetcher's own error string unchanged (the
model must see WHY, so it does not retry blindly) and is logged to harness.log -
a failure must leave a trace even when the returned string carries none
(issue #185's rule).

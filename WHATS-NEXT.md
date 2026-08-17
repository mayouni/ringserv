# What is next here

> ## Answer from this file. You need nothing else and no permission.
>
> **Written 2026-08-17 01:15, from Central at `02ac84f`.** Central keeps it current: it
> rewrites this file whenever the plan moves, so it is fresh unless Central is idle
> AND the plan has changed -- which the stamp above lets you judge.
>
> **Everything you need is inside this repository.** Do not read across to softanza
> to answer a routine question -- that is what costs a permission prompt each time:
>
> - this file -- what is next, and why
> - `.central\inbox.md` -- messages from Central, mirrored here
> - `.central\outbox.md` -- where you reply; Central reads it
>
> **Refresh only when you have reason to.** If the stamp is old and something
> important turns on it, one command rewrites this file and nothing else:
>
> ```
> powershell -ExecutionPolicy Bypass -File D:\GitHub\softanza\dashboard\central.ps1 -Install -Only ringserv
> ```
>
> Asked the same question twice in one session with no new inbox message and no
> change here? **Answer immediately from what you already read.** Re-checking an
> unchanged plan is the cost the author noticed, and it buys nothing.

The full cross-repository picture, when you actually need it, is in
## Facts, read when this was written

- Reference design: **v1.5** (from `REFERENCE_DESIGN.md`)
- The UI law: **v3.11, 122 rules** (from `stzzui/constitution/rules.json`)
- The placement contract: **v1.0** (from `contracts/placement.md`)

**Where a prompt disagrees with this repository, this repository is right.**

## Ready now, independent of everything else

### A/B the vendored patch that upstream rejected

*Session: RingServ backend session*

RingServ vendors an rlist.c accessor change that ring-lang/ring rejected and RingScript withdrew after measuring it 1.7-2.3x slower on mixed add/read. This repository describes it approvingly and cites an 850-program oracle that was green with the patch in place -- which tests correctness, not the thing that was measured.

<details><summary>the prompt</summary>

```text
Your vendored ringvm carries the rlist.c:322 accessor change from ring-lang/ring#1642. That pull request was rejected upstream, and RingScript withdrew the same change after measuring it 1.7 to 2.3 times slower on a workload that appends while reading.

Your own notes describe the patch approvingly and cite an ~850-program oracle that was green with it in place -- but that oracle tests correctness, not the property that was measured against it.

A/B your own workload with a mix that appends while reading, and record the result in VENDOR_PATCHES.md whichever way it falls. Nobody is deciding this for you; it is flagged because the evidence you have does not answer the question you need answered.

Append a SESSION-LOG line with the numbers.
```

</details>

### Adopt the placement rules and settle whether RingServ still uses the ZQL grammar

*Session: RingServ backend session*

Four phases have shipped. The two phases this shapes -- the checker and the topology work -- are both still unbuilt, so it costs a document now and a rewrite later.

<details><summary>the prompt</summary>

```text
Read D:\GitHub\softanza\prompts\07-ringserv-adoption.md and carry it out.

It was refreshed on 2026-08-14 against this repository as it actually stands, but check anyway: where the prompt and the tree disagree, the tree is right. In particular, verify what the query surface became in Phase 3 before pinning anything.
```

</details>

## Talking back

Your mailbox is `D:\GitHub\softanza\mailbox\ringserv.md`. Open it now and keep it open --
that is what makes Central's appends arrive as messages.

Disagree by appending a `DISAGREE` block **with the local fact Central cannot see**;
a preference is not a disagreement. Central answers with `ACCEPT` or `INSIST`; you then
`CLOSE`. Three messages, never a fourth, and you never disagree twice. **If Central
does not answer, proceed and record what you did.**

Report conclusions -- not activity -- as one line in `softanza\dashboard\SESSION-LOG.md`.

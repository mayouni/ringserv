# What is next here

> ## Answer from this file. You need nothing else and no permission.
>
> **Written 2026-08-20 11:26, from commit cece083+dirty, from Central at `cece083`.** Central keeps it current: it
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

### Swap the vendored VM for a patched Ring -- RingScript already did, and measured it

*Session: RingServ session*

ringvm/ here is still the official Ring 1.27 distribution, per your own docs/VENDOR_PATCHES.md, carrying local patches that upstream has since absorbed. RingScript shipped this same swap on 2026-08-16 and is now on master 8a89cc00c2 with its patch set down from seven to four. This row existed since 2026-08-17 but was addressed to RingScript and named you only in its prose, so it never reached your board -- that is Central's error and it is stated here rather than backdated.

<details><summary>the prompt</summary>

```text
Your vendored ringvm is the official Ring 1.27 distribution and is missing fixes that landed upstream after it -- private-in-eval, strtod/musl, memcpy zero-byte, empty-catch stack, name folding, operator overloading among them.

Treat it as one swap rather than several errands: move to a patched base, re-apply the patches docs/VENDOR_PATCHES.md marks as yours, run your gates, and record what moved.

TWO MEASUREMENTS FROM RINGSCRIPT, WHICH ARE ITS TREE AND NOT YOURS -- check them against your own before you rely on either. The delta it measured was ELEVEN fixes, not the six this row said for three days. And stock-1.27-against-master is 91 lines with no feature in it, which is small enough that the swap may cost less than the tracking. Three of its seven local patches became upstream code and were deleted rather than re-applied; yours are documented separately and may or may not have.

If your own reading says the swap is not worth it, that is a complete answer -- say so with the numbers and the row closes.
```

</details>

### DONE 2026-08-17 -- ran, measured indifferent, and the patch then left with the VM swap

*Session: RingServ backend session*

CLOSED BY RINGSERV and reported 2026-08-19: it ran the A/B on 2026-08-17, the upstream objection reproduced, RingServ measured indifferent, and the accessor patch then left with the vendored-VM swap -- so the condition this row carried, run it only if the patch is still present afterwards, resolves to nothing to run. The row survived two days after the work because a generated board can count commits and cannot know a row is finished.

<details><summary>the prompt</summary>

```text
Your vendored ringvm carries the rlist.c:322 accessor change from ring-lang/ring#1642. That pull request was rejected upstream, and RingScript withdrew the same change after measuring it 1.7 to 2.3 times slower on a workload that appends while reading.

Your own notes describe the patch approvingly and cite an ~850-program oracle that was green with it in place -- but that oracle tests correctness, not the property that was measured against it.

A/B your own workload with a mix that appends while reading, and record the result in VENDOR_PATCHES.md whichever way it falls. Nobody is deciding this for you; it is flagged because the evidence you have does not answer the question you need answered.

Append a SESSION-LOG line with the numbers.
```

</details>

### DONE 2026-08-18 -- both halves closed, placement adopted and paid in phase 6

*Session: RingServ backend session*

CLOSED BY RINGSERV and reported 2026-08-19. The ZQL half was settled on 08-14 by REMOVAL -- no framework dialect, plain SQL over SQLite -- and the checker shipped in phase 5. The placement half was done 08-17, C3 and C2 adopted, and phase 6 shipped COMPLETE on 08-18 including the contract's owed placement case, paid online and offline. RingServ also answered the 2.1 question RingScript raised, in its 08-18 12:40 memo.

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

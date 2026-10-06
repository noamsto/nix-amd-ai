# Repo conventions

## Credit carried patches with `Co-authored-by:`

When a commit carries someone else's work — their patch, their fix, their
measurements — add a trailer:

```
Co-authored-by: Their Name <their@email>
```

Take the name and email verbatim from their commit (`git log --format='%an <%ae>'`
on their branch) or from the PR's commit list. A trailer that doesn't match a
GitHub account is silently ignored.

**The trailer must be in a commit message on the branch, not the PR body.** This
repo is squash-only with `squash_message = COMMIT_MESSAGES`, so the squash
commit body is assembled from branch commit messages; anything written only in
the PR description is dropped on merge.

**Why:** GitHub counts co-authors in the contributors graph and on their profile.
Prose credit in a commit body reads fine and counts for nothing. This repo's most
valuable contributions arrive as measurements and diagnosis in issue threads
rather than as commits, so the graph already undercounts them badly — a trailer
is the one form of credit that is permanent and needs no upkeep.

This exists because it was got wrong: #98 carried @puffnfresh's fastflowlm fix
from #93, credited it in prose, and shipped him invisible.

The case to watch for is a contributor PR that can't be merged as-is — targeted
at a stale branch, or superseded by a rewrite. Carrying the change by hand is
often right; dropping the attribution with it is not.

## Don't add a credits section to the README

Credit at the point of use instead, next to the data it belongs to:

```markdown
Halo measurements above contributed by [@expelledboy](https://github.com/expelledboy) (#42).
```

Inline credit lives inside the unit that gets rewritten, so it is updated or
deleted along with the claim it describes and cannot drift out of sync. A
standalone credits table has the opposite property: it needs a manual edit per
contributor, and it goes *actively wrong* when a figure is re-measured by someone
else — a misattributed measurement is worse than an unattributed one.

## Bench PRs conflict on the `bench-logs/README.md` index

Every bench PR adds a row to that index, so parallel or stacked bench PRs
conflict there; expect it. Before merging, rebase onto the default branch and
keep every row from both sides in the table's existing order; change nothing
else in the file. If the PR has a stacked child, the rebase rewrites the
child's base: rebase the child with
`git rebase --onto <new parent> <old parent head>`, not a plain rebase.

**Why:** this is the usual reason a bench PR shows as conflicting, and the
stacked-child consequence is easy to miss.

## Hardware-gated claims

Numbers in this repo are hardware-specific and rarely transfer. Say which host a
measurement came from, and don't reuse a conclusion across GPU targets: rocWMMA
is a net regression on gfx1150 and expected to win on gfx1151.

When a claim hasn't been measured, say so rather than naming a plausible cause.
`docs/halo-bringup-checklist.md` tracks what is still hardware-gated.

# Contributing

Thanks for wanting to help. This file is short on purpose.

## Before you start

For anything larger than a bug fix, open an issue first. `lupa` is a small, opinionated
codebase and a design conversation costs both of us less than a rejected pull request.

Read [STYLE.md](./STYLE.md) before writing code. It binds everything added from now on,
including contributions.

Every change needs a test. `tests/` shows the expected shape.

## Running things

This project is built with [lde](https://lde.sh).

## Sign-off

Every commit must be signed off, certifying the [Developer Certificate of Origin
1.1](https://developercertificate.org/):

```sh
git commit -s
```

That appends a line using your configured git identity:

```
Signed-off-by: Your Name <you@example.com>
```

By signing off, you confirm you wrote the contribution or otherwise have the right to
submit it under this project's license, and that you agree to the terms below.

## Contribution terms

You keep the copyright to your contribution. To submit it, you grant David Cruz a
perpetual, worldwide, non-exclusive, royalty-free, irrevocable license to reproduce,
prepare derivative works of, publicly display, sublicense, and distribute your
contribution and such derivative works.

This grant includes the right to license your contribution under **any license terms**,
including terms other than the ones this project currently uses. That is deliberate:
`lupa` may in future be offered under a commercial license alongside its open-source one,
and every contribution has to be usable under both for that to be possible. Your
contribution stays available under the project's open-source license either way.

## What not to send

- Code you did not write and cannot license, including code copied from another project,
  decompiled binaries, or generated output whose terms you cannot state.
- Anything under a console SDK or similar NDA. Those targets live in a separate
  repository for that reason.

## Reporting bugs

Include the `lde` version (`lde --version`), your OS and architecture, the backend
(`VULKAN=1` or the default OpenGL path), and the smallest reproduction you can manage.
A failing test is the ideal bug report.

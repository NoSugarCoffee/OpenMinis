# Contributing

Thanks for your interest in Pico, a modified version of
[OpenMinis](https://github.com/OpenMinis/OpenMinis).

## Where things go

- **Pico's own features** (remote hosts, pairing, the host's browser and screen, proactive push,
  `minis-hostd`): [issues](https://github.com/NoSugarCoffee/Pico/issues) and
  [pull requests](https://github.com/NoSugarCoffee/Pico/pulls) here, at NoSugarCoffee/Pico.
- **Everything Pico inherits from OpenMinis**: the problem is usually upstream's too, so report it to
  [OpenMinis](https://github.com/OpenMinis/OpenMinis/issues) as well, following its
  [contribution rules](https://github.com/OpenMinis/OpenMinis/blob/main/CONTRIBUTING.md). Its
  [AwesomeMinis](https://github.com/OpenMinis/AwesomeMinis) and
  [MinisSkills](https://github.com/OpenMinis/MinisSkills) take use cases and skills, and both work in
  Pico.

## Filing a good issue

The more of this you can give, the faster it gets fixed:

- Platform and version (Settings → About shows both), and the `minis-hostd` version for host issues
- What you expected, what happened instead
- Steps to reproduce, or the prompt that triggered it
- Which model / provider was selected, if relevant
- Logs, if the app produced any (Settings → Logs)

## Changing the code

Read [docs/remote-agent/decisions.md](docs/remote-agent/decisions.md) first. New code goes in new
files, and edits to upstream files stay minimal and are marked `// fork(remote-host):`, so OpenMinis
changes keep merging (D7). Internal names stay upstream's (D23).

## Using the source

The code is GPLv3, like OpenMinis. You are free to fork it, modify it and run your own build —
see [BUILDING.md](BUILDING.md). The licence obliges you to publish the source of anything you
distribute, to keep it under GPLv3, and to say that it is modified.

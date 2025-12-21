---
name: game
description: Vision-based game controller with automated strategies
---

# Game Controller Skill

Runs a vision-based game loop that tracks colored objects and sends keypresses.

## Usage

```
/game --in-app "Python" --target green --self blue --strategy chase --duration 60
```

## Arguments

| Argument | Description | Default |
|----------|-------------|---------|
| `--in-app <name>` | Target application (required) | |
| `--target <color>` | Color to track/chase | green |
| `--self <color>` | Your object's color | blue |
| `--strategy <type>` | Movement strategy | chase |
| `--keys <type>` | arrows or wasd | arrows |
| `--fps <n>` | Frames per second | 10 |
| `--duration <sec>` | How long to run | 30 |
| `--axis <type>` | both, x, or y | both |
| `--no-walls` | Disable wall avoidance | |
| `--debug` | Show debug info | |

## Strategies

| Strategy | Behavior |
|----------|----------|
| `chase` | Move toward target (Snake chasing food) |
| `flee` | Move away from target (avoiding enemies) |
| `mirror` | Match target position on axis (Pong paddle) |
| `patrol` | Move in pattern, react when target appears |

## Colors

Supported colors: red, green, blue, yellow, orange, purple, white, black, gold, cyan, magenta

Or use hex (`#FF5500`) or RGB (`rgb(255,85,0)`)

## Examples

```
# Snake game - chase green food as blue snake
/game --in-app "Python" --target green --self blue --strategy chase

# Pong - mirror ball movement
/game --in-app "Pong" --target white --strategy mirror --axis y

# Avoid enemies
/game --in-app "Game" --target red --strategy flee --duration 120
```

## Implementation

```bash
./bin/joystick.sh $ARGS
```

## Note

This is also available as a subagent (`/agent game-controller`) for more sophisticated autonomous gameplay with higher-level strategy decisions.

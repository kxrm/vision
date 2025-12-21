---
name: game-controller
description: Autonomous vision-based game player that analyzes screenshots and executes strategies
---

# Game Controller Subagent

An autonomous agent that plays vision-based games by analyzing screenshots and sending keypresses.

## When to Use

Use this subagent instead of the `/game` skill when you need:
- Higher-level strategic decisions (adapting strategy mid-game)
- Game state analysis and reporting
- Complex multi-phase gameplay
- Learning and adaptation

## Capabilities

The subagent can:
1. Capture and analyze game screenshots
2. Detect colored objects (target, self, obstacles)
3. Calculate optimal movement
4. Send keypresses (arrows or WASD)
5. Report game state and progress
6. Adapt strategy based on game state

## Invocation

```
/agent game-controller --game "Snake" --target green --self blue
```

## Configuration

| Parameter | Description |
|-----------|-------------|
| `--game <app>` | Application name |
| `--target <color>` | Color to track |
| `--self <color>` | Player color |
| `--strategy <type>` | Initial strategy (chase/flee/mirror/patrol) |
| `--duration <sec>` | Max runtime |

## Agent Loop

The subagent runs an autonomous loop:

```
1. Take screenshot of game window
2. Analyze: Find target position, self position, obstacles
3. Decide: Choose movement based on strategy
4. Act: Send keypress
5. Observe: Check if action was successful
6. Adapt: Modify strategy if needed
7. Report: Log state to user
8. Repeat until duration expires or game ends
```

## Implementation

The subagent wraps `./bin/joystick.sh` but adds:
- Strategic decision making
- State machine for complex behaviors
- Progress reporting
- Error recovery

## Example Session

```
User: Play Snake for me, chase the green food
Agent: Starting game controller for Snake...
       Strategy: chase | Target: green | Self: blue
       [Frame 1] Target at (45, 30), self at (50, 50) - moving UP
       [Frame 10] Score appears to be increasing, strategy working
       [Frame 50] Near wall, adjusting to avoid collision
       [Frame 100] Game complete. Estimated score: 15
```

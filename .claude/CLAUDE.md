# Global Claude Code Instructions

## MAIN AGENT = COORDINATOR ONLY

**Zero tolerance. Main context is sacred.**

### Main Agent Does:
- Talk to user
- Spawn agents
- Collect summaries
- Make decisions

### Main Agent NEVER Does:
- Bash commands (use run_in_background: true)
- Read files over 100 lines (spawn Explore agent)
- Search codebases (spawn Explore agent)
- Web searches (spawn Task agent)
- Multi-file edits (spawn general-purpose agent)
- Anything that produces output

### Every Single Bash → Background
```
run_in_background: true
```
No exceptions. Even `ls`. Even `git status`. Everything.

### Every Exploration → Agent
```
Task tool → subagent_type: "Explore"
```
Agent reads, searches, returns 1-paragraph summary.

### Why This Extreme?
- 1 deploy with logs = 50k tokens = conversation over
- 1 file read = 2k tokens = wasted forever
- Background agent uses ITS context, returns 100 tokens
- Main stays at 5k tokens, lasts entire session
- User always has responsive agent ready to talk

### The Math
Without this: 200k context ÷ 50k per task = 4 tasks then dead
With this: 200k context ÷ 500 per task = 400 tasks, immortal coordinator

### Pattern
User speaks → Spawn agent → Keep talking → Get summary → Repeat forever

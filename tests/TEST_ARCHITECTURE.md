# Testing Architecture Specification

## Test Mode Components

```
┌─────────────────────────────────────────────────────────────┐
│                        TEST MODE                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│   REAL                          MOCKED                       │
│   ────                          ──────                       │
│   Mac server                    Audio recording              │
│   Claude Code                   Whisper transcription        │
│   tmux sessions                 TTS playback                 │
│   JSONL files                                                │
│   Sub-agents                                                 │
│   iPhone UI                                                  │
│   TCP connection                                             │
│   Haiku API                                                  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Message Flow (Test Mode)

```
Mac                          iPhone                      Claude
────                         ──────                      ──────

send command ──────────────► show "recording"
  {simulateRecording,
   conversationId: A,
   text: "Remember SUNRISE"}
                             show transcription
                             (mocked, no Whisper)

inject to tmux A ─────────────────────────────────────► receives prompt

                                                        thinks...

                                                        writes JSONL

detect JSONL ◄────────────────────────────────────────

send response ─────────────► show response
                             play TTS (mocked, silent)
```

## Commands (Mac → iPhone)

```
{type: "command", action: "simulateRecording", conversationId: "A", text: "..."}
{type: "command", action: "showResponse", conversationId: "A", text: "..."}
{type: "command", action: "showConversationCreated", conversationId: "C", parent: "A"}
```

## The Story

```
1. Mac: simulateRecording(A, "Remember SUNRISE")  [audio mocked]
2. iPhone: shows transcription                    [whisper mocked]
3. Mac: inject to tmux A                          [real]
4. Claude A: responds                             [real]
5. Mac: send response to iPhone                   [real]
6. iPhone: shows response, plays TTS              [TTS mocked]

7. Mac: simulateRecording(B, "Remember MOONLIGHT") [audio mocked]
8. iPhone: shows transcription                     [whisper mocked]
9. Mac: inject to tmux B                           [real]
10. Claude B: responds                             [real]
11. Mac: send response to iPhone                   [real]
12. iPhone: shows response                         [TTS mocked]

13. Mac: simulateRecording(A, "What word?")
14. Claude A: "SUNRISE"                            [real - context preserved]
15. VERIFY: A says SUNRISE, not MOONLIGHT

16. Mac: simulateRecording(B, "What word?")
17. Claude B: "MOONLIGHT"                          [real - isolation verified]
18. VERIFY: B says MOONLIGHT, not SUNRISE

19. Mac: simulateRecording(A, "Research something")
20. Claude A: spawns sub-agent C                   [real]
21. Mac: detect new JSONL
22. Mac: showConversationCreated(C, parent: A)
23. iPhone: shows new conversation C
24. Claude C: works                                [real]
25. Mac: send C response to iPhone
26. iPhone: shows C response

27. Mac: simulateRecording(C, "Go deeper")
28. Claude C: continues                            [real - user talks to sub-agent]
29. Mac: send C response to iPhone

30. Claude C: returns to A
31. Claude A: responds with findings               [real]
32. Mac: send A response to iPhone

33. Mac: simulateRecording(B, "Any research?")
34. Claude B: "No"                                 [real - isolation verified]
35. VERIFY: B knows nothing about A or C
```

## Invariants

```
I1: A only knows A
I2: B only knows B
I3: C is child of A
I4: C can talk to user directly
I5: B never sees A, B, or C
I6: User can switch between A, B, C freely
```

## Control Summary

```
Mac = brain (runs test, verifies invariants)
iPhone = screen (displays UI, mocks audio/TTS)
Claude = real (actual AI responses)
```

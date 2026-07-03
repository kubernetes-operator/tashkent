# Harness Cron Trigger

Harness UI에서 Pipeline Trigger를 추가한다.

## 추천 Cron

| 목적 | Cron |
|---|---|
| 매일 새벽 2시 | `0 2 * * *` |
| 6시간마다 | `0 */6 * * *` |
| 매시간 | `0 * * * *` |

초기 권장값:

~~text
0 2 * * *
~~

## 주의

- Harness Pipeline의 `projectIdentifier`, `orgIdentifier`는 실제 Harness 값으로 수정해야 한다.
- Harness Secret에는 `openai_api_key` 이름으로 OpenAI API Key를 등록한다.
- 현재 1차 테스트 모델은 OpenAI API 없이도 실행 가능하다.

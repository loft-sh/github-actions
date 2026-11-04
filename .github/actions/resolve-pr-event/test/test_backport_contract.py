"""Guard compatibility between direct PR callers and workflow_run handoffs."""
from pathlib import Path
import re

WORKFLOW = Path(__file__).resolve().parents[3] / 'workflows' / 'backport.yaml'


def test_existing_callers_keep_the_original_event_as_fallback():
    text = WORKFLOW.read_text()
    assert "default: ''" in text.split('      pr-event:', 1)[1].split('      legacy-split:', 1)[0]
    assert 'fromJSON(inputs.pr-event || toJSON(github.event)).pull_request.merged == true' in text
    assert not re.search(r'github\.event\.(pull_request|action|label)', text)


def test_backport_action_receives_the_restored_payload_without_changing_other_steps():
    text = WORKFLOW.read_text()
    assert "if: inputs.pr-event != ''" in text
    assert 'event-json: ${{ inputs.pr-event }}' in text
    assert 'NODE_OPTIONS: ${{ steps.pr-event.outputs.node-options }}' in text
    assert 'RESOLVED_PR_EVENT_PATH: ${{ steps.pr-event.outputs.event-path }}' in text
    assert 'GITHUB_EVENT_PATH:' not in text
    assert 'cancel-in-progress: false' in text
    assert 'needs: [backport, legacy-backport]' in text
    assert 'continue-on-error: true' in text

#!/usr/bin/env shellspec

Describe 'stamp-kata-containerd-config systemd unit'
    SERVICE_UNIT='./parts/linux/cloud-init/artifacts/stamp-kata-containerd-config.service'
    STAMP_SCRIPT='./parts/linux/cloud-init/artifacts/stamp-kata-containerd-config.sh'

    It 'does not bind the stamp service lifecycle to containerd'
        When call cat "$SERVICE_UNIT"
        The status should be success
        The output should not include 'After=containerd.service'
        The output should not include 'Requires=containerd.service'
    End

    It 'restarts containerd explicitly from the stamp script'
        When call grep -F 'systemctl restart containerd' "$STAMP_SCRIPT"
        The status should be success
        The output should include 'systemctl restart containerd'
    End
End
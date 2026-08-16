# BEGIN_DP_RESUME_OPERATOR_NOTICE
# Operational guidance only — never auto-executes aella_cli resume / restart.
# OS upgrade pre-check MOTD (xenial→bionic / bionic→focal) asks operators to
# manually `pause` in aella_cli before the next hop; Phase 2 bringup does not
# clear that platform pause state.
emit_dp_resume_notice_line() {
    local line="$1"
    echo "$line"
    # When detached, stdout is /dev/null; always append so the bringup log keeps
    # the operator checklist next to "Bringup complete:".
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "$line" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

emit_dp_resume_pre_detach_notice() {
    emit_dp_resume_notice_line "============================================================"
    emit_dp_resume_notice_line "IMPORTANT: DP SERVICE RESUME MAY BE REQUIRED"
    emit_dp_resume_notice_line "============================================================"
    emit_dp_resume_notice_line "The OS upgrade pre-check may have paused the DP service stack."
    emit_dp_resume_notice_line "Phase 2 bringup does NOT automatically clear the platform pause state."
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "Do NOT run resume while bringup is still running."
    emit_dp_resume_notice_line "Wait until the bringup log shows:"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "  Bringup complete:"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "After bringup completes, run:"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "  sudo aella_cli"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "Then inside the CLI:"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "  show status"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "If the status contains:"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "  System paused. Type resume in cli to start data processor services"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "run:"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "  resume"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "Then wait for services to start and run:"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "  show status"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "DP_RESUME_AUTOMATIC=NO"
    emit_dp_resume_notice_line "DP_RESUME_CHECK_REQUIRED_AFTER_BRINGUP=YES"
    emit_dp_resume_notice_line "DP_RESUME_COMMAND=aella_cli_then_resume"
    emit_dp_resume_notice_line "DP_RESUME_EARLIEST_POINT=AFTER_BRINGUP_COMPLETE"
    emit_dp_resume_notice_line "============================================================"
}

emit_dp_resume_post_complete_notice() {
    emit_dp_resume_notice_line "============================================================"
    emit_dp_resume_notice_line "NEXT REQUIRED CHECK: DP PAUSE STATE"
    emit_dp_resume_notice_line "============================================================"
    emit_dp_resume_notice_line "Phase 2 bringup has completed, but product services may still be paused."
    emit_dp_resume_notice_line "DP services may still be paused from the OS upgrade pre-check."
    emit_dp_resume_notice_line "Check the pause state after bringup completes."
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "Run:"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "  sudo aella_cli"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "Then:"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "  show status"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "If \"System paused\" is displayed:"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "  resume"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "Waiting for DP pods/services to start may take some time."
    emit_dp_resume_notice_line "After waiting for the DP services to start:"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "  show status"
    emit_dp_resume_notice_line ""
    emit_dp_resume_notice_line "PHASE2_BRINGUP=COMPLETE"
    emit_dp_resume_notice_line "DP_PLATFORM_PAUSE_STATE=REQUIRES_OPERATOR_CHECK"
    emit_dp_resume_notice_line "DP_PRODUCT_RUNTIME_VALIDATION=NOT_COMPLETE"
    emit_dp_resume_notice_line "NEXT_REQUIRED_ACTION=CHECK_AELLA_CLI_STATUS_AND_RESUME_IF_PAUSED"
    emit_dp_resume_notice_line "DP_RESUME_AUTOMATIC=NO"
    emit_dp_resume_notice_line "DP_RESUME_CHECK_REQUIRED=YES"
    emit_dp_resume_notice_line "PRODUCT_VALIDATION_PENDING=YES"
    emit_dp_resume_notice_line "============================================================"
}
# END_DP_RESUME_OPERATOR_NOTICE


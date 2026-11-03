// Removable diagnostic only: samples arrive on the existing Godot executor.
// These are callback observations, never native OpenXR call or pixel counts.
internal sealed class FrameObservation(long stopwatchFrequency)
{
    public const int TransitionLimit = 64;
    long frames, increasing, equal, decreasing, positive, zero, negative;
    long canRenderTrue, canRenderFalse, transitions, omitted;
    long? firstPredicted, lastPredicted, firstElapsed, lastElapsed;
    string? firstState, lastState;
    readonly List<StateChange> changes = new(TransitionLimit);

    internal sealed record StateChange(long callback, long elapsed_ticks,
        string from, string to, long predicted_time, bool can_render);

    public void Record(long predictedTime, bool canRender, string state, long elapsedTicks)
    {
        frames++;
        firstPredicted ??= predictedTime;
        firstElapsed ??= elapsedTicks;
        if (lastPredicted is long previous)
        {
            if (predictedTime > previous) increasing++;
            else if (predictedTime == previous) equal++;
            else decreasing++;
        }
        if (predictedTime > 0) positive++;
        else if (predictedTime == 0) zero++;
        else negative++;
        if (canRender) canRenderTrue++;
        else canRenderFalse++;
        firstState ??= state;
        if (lastState is not null && lastState != state)
        {
            transitions++;
            if (changes.Count < TransitionLimit)
                changes.Add(new(frames, elapsedTicks, lastState, state, predictedTime, canRender));
            else omitted++;
        }
        lastPredicted = predictedTime;
        lastElapsed = elapsedTicks;
        lastState = state;
    }

    public object Snapshot() => new
    {
        scope = "FramePostDraw samples after StartXR returns; cumulative for this observer lifetime",
        frame_post_draw_count = frames,
        first_predicted_time = firstPredicted, last_predicted_time = lastPredicted,
        increasing_predicted_time_count = increasing,
        equal_predicted_time_count = equal, decreasing_predicted_time_count = decreasing,
        positive_predicted_time_count = positive, zero_predicted_time_count = zero,
        negative_predicted_time_count = negative,
        can_render_true_count = canRenderTrue, can_render_false_count = canRenderFalse,
        first_callback_elapsed_ticks = firstElapsed, last_callback_elapsed_ticks = lastElapsed,
        stopwatch_frequency = stopwatchFrequency,
        first_session_state = firstState, last_session_state = lastState,
        sampled_state_transition_count = transitions,
        retained_state_transitions = changes.ToArray(), omitted_state_transitions = omitted,
        state_transition_limit = TransitionLimit,
        native_frame_call_count = (long?)null, direct_should_render = (bool?)null
    };
}

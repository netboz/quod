"""Decision owner for one manual opportunity; availability never grants authority."""
class Supervision:
    def __init__(self, started, send_finish):
        self.started=started
        self.send_finish=send_finish
        self.participant_deadline=None
        self.auth_deadline=None
        self.auth_expires_ms=None
        self.finish_reason=None
        self.finish_at=None
        self.latest=None

    @property
    def deadline(self):
        return min(self.started+2100,
                   self.participant_deadline if self.participant_deadline is not None else self.started+180,
                   self.auth_deadline if self.auth_deadline is not None else self.started+2100)

    def stop(self, reason, now):
        if self.finish_reason is not None:return False
        # Fence the attempt before I/O: an uncertain stdin write is never retried.
        self.finish_reason=reason;self.finish_at=now
        self.send_finish(reason)
        return True

    def marker(self, name, data, now, wall):
        self.latest=data
        self.cutoff(now)
        if self.auth_deadline is None and 'expires_ms' in data:
            self.auth_expires_ms=data['expires_ms']
            self.auth_deadline=now+max(0,data['expires_ms']/1000-wall)
        if data.get('expired') is True:
            self.stop('auth_expired',now)
        if name=='VR263_BLOCKER':self.stop('native_admission_failure',now)
        first=name=='VR263_READY' and self.participant_deadline is None and self.finish_reason is None
        if first:self.participant_deadline=now+1800
        self.cutoff(now)
        # STATE/STATUS availability is an observation only. Production owns the
        # locked controls and accepts subsequent refreshes; no close or renewal.
        return first and self.finish_reason is None

    def cutoff(self, now):
        if now<self.deadline:return False
        if self.auth_deadline is not None and now>=self.auth_deadline:reason='auth_expired'
        elif now>=self.started+2100:reason='outer_cutoff'
        elif self.participant_deadline is not None:reason='participant_cutoff'
        else:reason='preparation_failure'
        return self.stop(reason,now)

    def command(self, text, now):
        if text.strip() in ['', 'stop', 'finish']:return self.stop('participant_stop',now)
        return False

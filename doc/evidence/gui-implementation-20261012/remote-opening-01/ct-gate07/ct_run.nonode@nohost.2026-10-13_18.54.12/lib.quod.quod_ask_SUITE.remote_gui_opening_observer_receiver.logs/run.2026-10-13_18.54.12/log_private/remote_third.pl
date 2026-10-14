can_invoke(_Goal, _Principal, _Chain, _Ns).
third_blocked :- fail_with_reason(third_declined).
via_fourth(X) :- fourth::leaf(X).
dtx_write(X) :- assertz(dtx_third_mark(X)).
dtx_third_write_1(X) :- assertz(dtx_third_mark_1(X)).
dtx_third_write_2(X) :- assertz(dtx_third_mark_2(X)).
dtx_third_write_3(X) :- assertz(dtx_third_mark_3(X)).
dtx_third_write_4(X) :- assertz(dtx_third_mark_4(X)).
dtx_third_write_5(X) :- assertz(dtx_third_mark_5(X)).
dtx_third_write_6(X) :- assertz(dtx_third_mark_6(X)).
dtx_third_write_7(X) :- assertz(dtx_third_mark_7(X)).
dtx_third_write_8(X) :- assertz(dtx_third_mark_8(X)).

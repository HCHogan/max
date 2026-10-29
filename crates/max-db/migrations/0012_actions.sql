-- What Max does rather than says, such as an unsend, has no platform id of
-- its own: QQ only answers that it went through. Such a delivery is sent
-- without one; a platform id still means sent. See "出站".

alter table deliveries drop constraint deliveries_check;
alter table deliveries add constraint deliveries_native_id_check
    check (status = 'sent' or native_id is null);

-- Each tool call of a turn, with what it returned, as text: what
-- history's `tools: true` searches and reads. The rows come from the run
-- kept with the turn's outcome, by tool_calls_of: the outcome's insert
-- writes them in the same statement, and those of the runs kept before
-- are filled in here. See "Recall" in docs/design/context.md.

-- A run's tool calls in order, the first 1: each with its arguments, a
-- line `key: value` for each field of an object (a string as it is,
-- anything else as JSON), or the text as the model wrote it where that
-- isn't an object; and the text of its result, '' for a call that has
-- none. The model's arguments may not be JSON at all.
create function tool_calls_of(run jsonb)
returns table (n integer, name text, arguments text, output text)
language sql stable parallel safe
as $$
    select c.n::integer,
           coalesce(c.kind->>'name', ''),
           coalesce(
               (select string_agg(
                           a.key || ': ' || case jsonb_typeof(a.value)
                               when 'string' then a.value #>> '{}'
                               else a.value::text
                           end,
                           E'\n')
                from jsonb_each(c.object) as a),
               c.kind->>'arguments',
               ''),
           coalesce(
               (select string_agg(p.part->>'text', E'\n' order by p.at)
                from jsonb_array_elements(r.kind->'output'->'parts')
                     with ordinality as p(part, at)
                where p.part->>'type' = 'text'),
               '')
    from (
        select e.item->'kind' as kind,
               row_number() over (order by e.at) as n,
               case when pg_input_is_valid(e.item->'kind'->>'arguments', 'jsonb') then
                   case when jsonb_typeof((e.item->'kind'->>'arguments')::jsonb) = 'object'
                        then (e.item->'kind'->>'arguments')::jsonb
                   end
               end as object
        from jsonb_array_elements(run->'transcript') with ordinality as e(item, at)
        where e.item->'kind'->>'type' = 'tool_call'
    ) c
    left join lateral (
        select e.item->'kind' as kind
        from jsonb_array_elements(run->'transcript') as e(item)
        where e.item->'kind'->>'type' = 'tool_result'
          and e.item->'kind'->>'call' = c.kind->>'id'
        limit 1
    ) r on true
$$;

create table tool_calls (
    turn_id bigint not null references turns,
    -- Its place among the turn's calls: t#N.n.
    n integer not null check (n >= 1),
    name text not null,
    arguments text not null,
    output text not null,
    primary key (turn_id, n)
);

insert into tool_calls (turn_id, n, name, arguments, output)
select o.turn_id, c.n, c.name, c.arguments, c.output
from turn_outcomes o, tool_calls_of(o.run) c
where o.run is not null;

-- As messages' text: a term of three characters or more finds its rows by
-- the index.
create index on tool_calls using gin (lower(arguments || E'\n' || output) gin_trgm_ops);

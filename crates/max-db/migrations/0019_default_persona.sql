-- `/persona default` meant the default persona, in the Haskell max as
-- here, but was kept as a persona of that one word.
update conversation_settings set persona = null where persona = 'default';

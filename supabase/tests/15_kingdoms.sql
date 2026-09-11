-- 0024: ten kingdoms instead of one team.
--
-- The claim this file exists to defend is the counter-intuitive one:
-- AN INCOMPLETE KINGDOM IS LEGAL. Everything else here is ordinary plumbing,
-- but that one is easy to "fix" into a validation on the way in, and doing so
-- would break the editor in a way no test would otherwise notice -- a store
-- that refuses three cards is a store that forgets what you were choosing
-- every time you leave the page.
--
-- So the split is asserted from both ends. The cleaner and save_kingdom take a
-- half-built kingdom happily; deck_of, asked at the moment it matters, refuses
-- to field it and hands back the default instead. Relaxed editor, strict
-- match, and the same data in both.
\set ON_ERROR_STOP on
\pset pager off

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('c1110000-0000-0000-0000-00000000001c','k1@x.com','{"username":"kingy"}'),
  ('d1110000-0000-0000-0000-00000000001d','k2@x.com','{"username":"queeny"}');

create or replace function t_k(p_id uuid) returns jsonb
language sql stable as $$ select kingdoms from public.profiles where id = p_id $$;

create or replace function t_sel(p_id uuid) returns text
language sql stable as $$ select kingdom from public.profiles where id = p_id $$;

create or replace function t_kn(p_id uuid) returns int
language sql stable as $$ select jsonb_array_length(t_k(p_id)) $$;

-- Decks built from the live roster rather than written out. A test that names
-- five slugs is a test that fails the day somebody retires one, for a reason
-- that has nothing to do with kingdoms.
create or replace function t_crown() returns text
language sql stable as $$
  select slug from public.cards where is_active and royal order by sort limit 1 $$;

create or replace function t_plain(p_n int) returns text[]
language sql stable as $$
  select array(select slug from public.cards
                where is_active and not royal order by sort limit p_n) $$;

-- five cards, exactly one crown
create or replace function t_legal() returns text[]
language sql stable as $$ select t_crown() || t_plain(public.deck_size() - 1) $$;

-- five cards, no crown at all
create or replace function t_crownless() returns text[]
language sql stable as $$ select t_plain(public.deck_size()) $$;

-- ===========================================================================
-- 1. the cleaner
-- ===========================================================================
select t_ok(public.cn_clean_kingdoms(null) = '[]'::jsonb,
            'null is no kingdoms');
select t_ok(public.cn_clean_kingdoms('"nope"'::jsonb) = '[]'::jsonb,
            'a string is not a list of kingdoms');
select t_ok(public.cn_clean_kingdoms('{"id":"k1"}'::jsonb) = '[]'::jsonb,
            'and neither is a single one outside a list');
select t_ok(public.cn_clean_kingdoms('[1,"two",null]'::jsonb) = '[]'::jsonb,
            'things that are not objects are dropped');

-- an id is the handle everything else uses
select t_ok(public.cn_clean_kingdoms('[{"name":"nameless"}]'::jsonb) = '[]'::jsonb,
            'a kingdom with no id is not a kingdom');
select t_ok(public.cn_clean_kingdoms('[{"id":"  "}]'::jsonb) = '[]'::jsonb,
            'and neither is one whose id is whitespace');
select t_ok(jsonb_array_length(public.cn_clean_kingdoms(
              jsonb_build_array(jsonb_build_object('id', repeat('x', 200))))) = 0,
            'an id nobody could have generated is refused');
select t_ok(jsonb_array_length(public.cn_clean_kingdoms(
              '[{"id":"k1"},{"id":"k1"},{"id":"k2"}]'::jsonb)) = 2,
            'a repeated id is somebody double-tapping, and the second goes');

-- ten, however many arrive
select t_ok(jsonb_array_length(public.cn_clean_kingdoms(
              (select jsonb_agg(jsonb_build_object('id', 'k' || g))
                 from generate_series(1, 40) g))) = public.cn_kingdom_cap(),
            'forty kingdoms become ten');
select t_ok(public.cn_kingdom_cap() = 10, 'and ten is ten');

-- the name
select t_ok(public.cn_clean_kingdoms('[{"id":"k1","name":"  Vale  "}]'::jsonb)
              -> 0 ->> 'name' = 'Vale',
            'a name is trimmed');
select t_ok(public.cn_clean_kingdoms('[{"id":"k1","name":"   "}]'::jsonb)
              -> 0 ->> 'name' is null,
            'a blank name is no name at all');
select t_ok(length(public.cn_clean_kingdoms(
              jsonb_build_array(jsonb_build_object('id','k1','name',repeat('z',100))))
              -> 0 ->> 'name') = public.cn_kingdom_name_max(),
            'and a long one is cut to the cap rather than refused');
-- Deliberately NOT given a default here. "Kingdom 3" is words, and which words
-- they are is a question about the reader's language -- so the client answers
-- it. A default written into the column would be English in a Spanish account
-- forever.
select t_ok(public.cn_clean_kingdoms('[{"id":"k1"}]'::jsonb) -> 0 ? 'name'
            and public.cn_clean_kingdoms('[{"id":"k1"}]'::jsonb) -> 0 ->> 'name' is null,
            'an unnamed kingdom keeps a null name for the client to fill in');

-- the icon
select t_ok(public.cn_clean_kingdoms(
              jsonb_build_array(jsonb_build_object('id','k1','icon',t_crown())))
              -> 0 ->> 'icon' = t_crown(),
            'an icon that is one of the roster''s own tokens is kept');
select t_ok(public.cn_clean_kingdoms('[{"id":"k1","icon":"not-a-card"}]'::jsonb)
              -> 0 ->> 'icon' is null,
            'and one that is not becomes nothing rather than a broken picture');

-- the deck
select t_ok(public.cn_clean_kingdoms(
              jsonb_build_array(jsonb_build_object('id','k1','deck', to_jsonb(t_legal()))))
              -> 0 -> 'deck' = to_jsonb(t_legal()),
            'a real deck goes through untouched');
select t_ok(jsonb_array_length(public.cn_clean_kingdoms(
              jsonb_build_array(jsonb_build_object('id','k1','deck',
                to_jsonb(array[t_crown(), t_crown()]))))-> 0 -> 'deck') = 1,
            'the same card twice is one card');
select t_ok(jsonb_array_length(public.cn_clean_kingdoms(
              '[{"id":"k1","deck":["nobody","nothing"]}]'::jsonb) -> 0 -> 'deck') = 0,
            'cards that are not in the roster are dropped');
select t_ok(jsonb_array_length(public.cn_clean_kingdoms(
              jsonb_build_array(jsonb_build_object('id','k1','deck',
                to_jsonb(array(select slug from public.cards where is_active order by sort)))))
              -> 0 -> 'deck') = public.deck_size(),
            'and a deck longer than the game allows is cut to length');
select t_ok(public.cn_clean_kingdoms('[{"id":"k1","deck":"five"}]'::jsonb)
              -> 0 -> 'deck' = '[]'::jsonb,
            'a deck that is not a list is an empty one');

-- THE HEADLINE
select t_ok(jsonb_array_length(public.cn_clean_kingdoms(
              jsonb_build_array(jsonb_build_object('id','k1','deck',
                to_jsonb(t_plain(2))))) -> 0 -> 'deck') = 2,
            'A HALF-BUILT KINGDOM SURVIVES THE CLEANER -- that is the design');
select t_ok(jsonb_array_length(public.cn_clean_kingdoms(
              jsonb_build_array(jsonb_build_object('id','k1','deck',
                to_jsonb(t_crownless())))) -> 0 -> 'deck') = public.deck_size(),
            'and so does a finished one with no crown in it -- the cleaner
             does not know the royal rule, deck_of does');

-- ===========================================================================
-- 2. which one is selected
-- ===========================================================================
select t_ok(public.cn_pick_kingdom('[{"id":"a"},{"id":"b"}]'::jsonb, 'b') = 'b',
            'a selection that points at something is kept');
select t_ok(public.cn_pick_kingdom('[{"id":"a"},{"id":"b"}]'::jsonb, 'ghost') = 'a',
            'one that points at nothing lands on the first, not on none');
select t_ok(public.cn_pick_kingdom('[{"id":"a"}]'::jsonb, null) = 'a',
            'and so does no selection at all');
select t_ok(public.cn_pick_kingdom('[]'::jsonb, 'a') is null,
            'with nothing to select, nothing is');

-- ===========================================================================
-- 3. whichever door it came in by
--
-- The update policy still lets a client write its own profile row directly, so
-- the functions are the pleasant path and not the only one. Same lesson 0016
-- learned about the avatar and 0022 about settings.
-- ===========================================================================
update public.profiles
   set kingdoms = '[{"id":"k1","name":"  Trim Me  ","icon":"not-a-card","deck":["ghost"]}]'::jsonb,
       kingdom  = 'nowhere'
 where id = 'c1110000-0000-0000-0000-00000000001c';
select t_ok(t_k('c1110000-0000-0000-0000-00000000001c') -> 0 ->> 'name' = 'Trim Me'
        and t_k('c1110000-0000-0000-0000-00000000001c') -> 0 ->> 'icon' is null,
            'a direct write is cleaned on the way in');
select t_ok(t_sel('c1110000-0000-0000-0000-00000000001c') = 'k1',
            'and a selection pointing nowhere is repointed at something real');

update public.profiles set kingdoms = '"rubbish"'::jsonb
 where id = 'c1110000-0000-0000-0000-00000000001c';
select t_ok(t_k('c1110000-0000-0000-0000-00000000001c') = '[]'::jsonb
        and t_sel('c1110000-0000-0000-0000-00000000001c') is null,
            'rubbish written straight at the column becomes nothing, and takes
             the selection with it');
select t_ok((select count(*) from public.profiles where kingdoms is null) = 0,
            'no profile anywhere has null kingdoms');

-- ===========================================================================
-- 4. saving one
-- ===========================================================================
select set_config('app.uid','c1110000-0000-0000-0000-00000000001c',false);

select public.save_kingdom('kA', 'The Vale', t_crown(), t_plain(2));
select t_ok(t_kn('c1110000-0000-0000-0000-00000000001c') = 1,
            'saving a kingdom saves a kingdom');
select t_ok(t_k('c1110000-0000-0000-0000-00000000001c') -> 0 ->> 'name' = 'The Vale',
            'with the name it was given');
select t_ok(jsonb_array_length(t_k('c1110000-0000-0000-0000-00000000001c') -> 0 -> 'deck') = 2,
            'AND TWO CARDS IN IT -- save_kingdom does not require a finished deck');
select t_ok(t_sel('c1110000-0000-0000-0000-00000000001c') = 'kA',
            'the first one you save is the one you are using');

select public.save_kingdom('kA', 'The Vale, renamed', t_crown(), t_plain(3));
select t_ok(t_kn('c1110000-0000-0000-0000-00000000001c') = 1,
            'saving the same id again replaces it rather than adding one');
select t_ok(t_k('c1110000-0000-0000-0000-00000000001c') -> 0 ->> 'name' = 'The Vale, renamed',
            'and the rename took');

select public.save_kingdom('kB', null, null, t_legal());
select t_ok(t_kn('c1110000-0000-0000-0000-00000000001c') = 2,
            'a different id is a different kingdom');
select t_ok(t_sel('c1110000-0000-0000-0000-00000000001c') = 'kA',
            'and saving a second does not quietly switch you onto it');

select t_ok(public.save_kingdom('kB', null, null, t_legal()) -> 1 ->> 'id' = 'kB',
            'the call hands back the whole list, not the one kingdom');

-- the one thing a finished deck IS held to
select t_raises(format('select public.save_kingdom(''kC'', null, null, %L::text[])', t_crownless()),
                'needs a royal',
                'a FINISHED deck with no crown is refused at the moment it is finished');

-- Two crowns needs two royal cards, and the roster has one until Queen Miah
-- arrives. Borrowed for one assertion and handed back in the same block -- the
-- rule is written for a roster that does not exist yet, which is exactly the
-- kind of rule that rots untested. The slug is captured in a variable rather
-- than found again afterwards: "put back whichever one is royal and is not
-- dereo" is a restore that hardcodes today's roster to undo itself.
do $$ declare v_borrowed text; begin
  select slug into v_borrowed from public.cards
   where is_active and not royal order by sort limit 1;
  update public.cards set royal = true where slug = v_borrowed;
  perform t_raises(format('select public.save_kingdom(''kC'', null, null, %L::text[])',
                          array(select slug from public.cards
                                 where is_active and royal order by sort)
                            || t_plain(public.deck_size() - 2)),
                   'exactly one royal',
                   'and a finished deck with two is refused too');
  update public.cards set royal = false where slug = v_borrowed;
end $$;
select t_ok((select count(*) from public.cards where is_active and royal) = 1,
            'the roster is back to one crown');

select t_raises(format('select public.save_kingdom(''kC'', null, null, %L::text[])',
                       array[t_crown(), t_plain(1)[1], t_plain(1)[1],
                             t_plain(2)[2], t_plain(3)[3]]),
                'no repeats',
                'and one with the same card twice as well');

-- but the half-built one those rules do not apply to still saves
select public.save_kingdom('kC', 'Barely started', null, array[t_crown(), t_crown()]);
select t_ok(t_kn('c1110000-0000-0000-0000-00000000001c') = 3,
            'while a half-built kingdom saves without an argument');

select t_ok(jsonb_array_length(
              (select k from jsonb_array_elements(t_k('c1110000-0000-0000-0000-00000000001c')) k
                where k->>'id' = 'kC') -> 'deck') = 1,
            'and the duplicate in it was quietly deduped, not refused');

-- ten of them
do $$ declare g int; begin
  for g in 4..public.cn_kingdom_cap() loop
    perform public.save_kingdom('k' || g, 'number ' || g, null, '{}'::text[]);
  end loop;
end $$;
select t_ok(t_kn('c1110000-0000-0000-0000-00000000001c') = public.cn_kingdom_cap(),
            'ten kingdoms fit');
select t_raises('select public.save_kingdom(''one-too-many'', null, null, ''{}''::text[])',
                'kingdoms', 'and an eleventh does not');
select t_ok(public.save_kingdom('kA', 'still editable', null, t_legal()) is not null,
            'but editing one of the ten still works at the cap');

-- nobody else's
select set_config('app.uid','',false);
select t_raises('select public.save_kingdom(''x'', null, null, ''{}''::text[])',
                'not signed in', 'a stranger cannot save one');
select t_raises('select public.delete_kingdom(''x'')',
                'not signed in', 'nor delete one');
select t_raises('select public.select_kingdom(''x'')',
                'not signed in', 'nor choose one');

-- ===========================================================================
-- 5. choosing and deleting
-- ===========================================================================
select set_config('app.uid','c1110000-0000-0000-0000-00000000001c',false);

select t_ok(public.select_kingdom('kB') = 'kB', 'you can move to another kingdom');
select t_ok(t_sel('c1110000-0000-0000-0000-00000000001c') = 'kB', 'and it sticks');
select t_ok(public.select_kingdom('nowhere') = 'kA',
            'choosing one that is not there lands on the first rather than on none');

select public.select_kingdom('kC');
select public.delete_kingdom('kC');
select t_ok(t_kn('c1110000-0000-0000-0000-00000000001c') = public.cn_kingdom_cap() - 1,
            'deleting one deletes one');
select t_ok(t_sel('c1110000-0000-0000-0000-00000000001c') = 'kA',
            'and deleting THE ONE YOU WERE USING lands you on another, not on nothing');
select public.delete_kingdom('never-existed');
select t_ok(t_kn('c1110000-0000-0000-0000-00000000001c') = public.cn_kingdom_cap() - 1,
            'deleting one that was never there changes nothing');

-- ===========================================================================
-- 6. the deck that is actually fielded
--
-- Where the relaxed editor meets the strict match. Everything above says a
-- half-built kingdom is allowed to exist; this section says it is not allowed
-- to walk onto a board.
-- ===========================================================================
-- Room to work. Section 4 filled the account to the cap on purpose, and a
-- section that then tries to save an eleventh is testing the cap again by
-- accident instead of testing what it came to test.
select public.delete_kingdom('k9');
select public.delete_kingdom('k10');

select public.save_kingdom('kA', 'The Vale', null, t_legal());
select public.select_kingdom('kA');
select t_ok(public.selected_deck('c1110000-0000-0000-0000-00000000001c') = t_legal(),
            'the selected kingdom is the one that is read');
select t_ok(public.deck_of('c1110000-0000-0000-0000-00000000001c') = t_legal(),
            'and a finished legal one is fielded as it stands');
select t_ok((select deck from public.profiles where id = 'c1110000-0000-0000-0000-00000000001c')
            = t_legal(),
            'profiles.deck is kept in step, so anything still reading the old
             column gets the right answer');

select public.save_kingdom('kHalf', 'Half a kingdom', null, t_plain(2));
select public.select_kingdom('kHalf');
select t_ok(public.selected_deck('c1110000-0000-0000-0000-00000000001c') = t_plain(2),
            'a half-built kingdom reads back as it was saved');
select t_ok(public.deck_of('c1110000-0000-0000-0000-00000000001c') = public.default_deck(),
            'BUT IT IS NOT FIELDED -- the match gets the default instead');

select public.save_kingdom('kNone', 'No crown', null, '{}'::text[]);
update public.profiles
   set kingdoms = (select jsonb_agg(case when k->>'id' = 'kNone'
                           then jsonb_set(k, '{deck}', to_jsonb(t_crownless())) else k end)
                     from jsonb_array_elements(kingdoms) k),
       kingdom = 'kNone'
 where id = 'c1110000-0000-0000-0000-00000000001c';
select t_ok(public.selected_deck('c1110000-0000-0000-0000-00000000001c') = t_crownless(),
            'a crownless five can reach the column by the direct door');
select t_ok(public.deck_of('c1110000-0000-0000-0000-00000000001c') = public.default_deck(),
            'and is still not fielded');

select public.select_kingdom('kA');
select t_ok(public.deck_of('c1110000-0000-0000-0000-00000000001c') = t_legal(),
            'switching back switches the army back');

-- A card retired after somebody picked it. Captured and handed back in one
-- block for the same reason as the borrowed crown above: "reactivate whatever
-- is inactive" would wake up cards that were meant to stay asleep.
do $$ declare v_gone text; begin
  v_gone := t_plain(1)[1];
  update public.cards set is_active = false where slug = v_gone;
  perform t_ok(public.deck_of('c1110000-0000-0000-0000-00000000001c') = public.default_deck(),
               'a kingdom holding a card that has since left the roster is not fielded');
  update public.cards set is_active = true where slug = v_gone;
end $$;
select t_ok((select count(*) from public.cards where is_active) = 11,
            'and the roster is whole again');

-- ===========================================================================
-- 7. the old door still opens
--
-- set_deck is what every client before this deploy calls, and the site deploys
-- separately from the database. It has to keep working, and it has to write
-- into the new shape rather than beside it.
-- ===========================================================================
select set_config('app.uid','d1110000-0000-0000-0000-00000000001d',false);
select t_ok(t_kn('d1110000-0000-0000-0000-00000000001d') = 0,
            'a fresh account has no kingdoms');
select t_ok(public.deck_of('d1110000-0000-0000-0000-00000000001d') = public.default_deck(),
            'and fields the default five');

select public.set_deck(t_legal());
select t_ok(t_kn('d1110000-0000-0000-0000-00000000001d') = 1,
            'the old call makes a kingdom out of what it was given');
select t_ok(public.deck_of('d1110000-0000-0000-0000-00000000001d') = t_legal(),
            'and that kingdom is the one fielded');
select t_ok((select deck from public.profiles where id = 'd1110000-0000-0000-0000-00000000001d')
            = t_legal(),
            'with the old column still saying the same thing');

select t_raises(format('select public.set_deck(%L)', t_crownless()),
                'needs a royal', 'and it still refuses a crownless five');
select t_raises('select public.set_deck(''{}''::text[])',
                'exactly', 'and still insists on a full one, unlike save_kingdom');

-- writing over an existing selection rather than adding beside it
select public.save_kingdom('kZ', 'second', null, '{}'::text[]);
select public.select_kingdom('kZ');
select public.set_deck(t_legal());
select t_ok(t_kn('d1110000-0000-0000-0000-00000000001d') = 2,
            'set_deck writes the SELECTED kingdom, it does not open a new one');
select t_ok(public.selected_deck('d1110000-0000-0000-0000-00000000001d') = t_legal(),
            'and the selected one is what it wrote');

-- ===========================================================================
-- 8. an account from before this migration
--
-- The backfill in 0024 runs once, against rows that existed when it ran; there
-- were none in this database, so running the statement here would be testing a
-- copy of itself. What is worth pinning is the safety net underneath it --
-- selected_deck falls back to profiles.deck -- because that is what catches a
-- row the backfill somehow missed, and nothing else would notice if it went.
-- ===========================================================================
update public.profiles set kingdoms = '[]'::jsonb, kingdom = null, deck = t_legal()
 where id = 'd1110000-0000-0000-0000-00000000001d';
select t_ok(public.selected_deck('d1110000-0000-0000-0000-00000000001d') = t_legal(),
            'a profile with the old column and no kingdoms still reads its deck');
select t_ok(public.deck_of('d1110000-0000-0000-0000-00000000001d') = t_legal(),
            'and still fields it');

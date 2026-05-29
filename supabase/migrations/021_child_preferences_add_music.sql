-- 021_child_preferences_add_music.sql
--
-- Add the 'music' category to child_preferences. The app now lets
-- parents/children record favorite and disliked music alongside the
-- existing food/color/clothing/interest categories, so the category
-- CHECK constraint from 011 has to allow the new value.
--
-- Also note: is_nogo (favorite vs. dislike) is no longer food-only —
-- the app surfaces a no-go toggle for every category now. No schema
-- change needed for that; the column already exists for all rows.

alter table familyfocal.child_preferences
  drop constraint if exists child_preferences_category_check;

alter table familyfocal.child_preferences
  add constraint child_preferences_category_check
  check (category in (
    'food', 'color', 'clothing', 'interest', 'music'
  ));

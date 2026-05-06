# frozen_string_literal: true

require_relative "test_helper"

class NamerTest < Minitest::Test
  def call(branch, **opts)
    FeatureDeploys::Namer.call(branch, **opts)
  end

  def test_basic_branch_name
    r = call("my-feature")
    assert_equal "my-feature", r.slug
    assert_equal "my_feature", r.db_slug
  end

  def test_strips_feature_prefix_uniformly
    r = call("feature/awesome-thing")
    assert_equal "awesome-thing", r.slug
    assert_equal "awesome_thing", r.db_slug
  end

  def test_strips_other_default_prefixes
    %w[feat/x fix/x bug/x bugfix/x chore/x hotfix/x release/x].each do |b|
      r = call(b)
      assert_equal "x", r.slug, "prefix-strip failed for #{b}"
      assert_equal "x", r.db_slug, "prefix-strip failed for #{b}"
    end
  end

  def test_db_slug_prepends_b_when_starting_with_digit
    r = call("123-numeric-start")
    assert_equal "123-numeric-start", r.slug
    assert_equal "b_123_numeric_start", r.db_slug
  end

  def test_db_slug_prepends_b_after_prefix_strip_when_starting_with_digit
    r = call("fix/123-bug")
    assert_equal "123-bug", r.slug
    assert_equal "b_123_bug", r.db_slug
  end

  def test_collapses_runs_of_special_chars
    r = call("feature/foo___bar---baz...qux")
    assert_equal "foo-bar-baz-qux", r.slug
    assert_equal "foo_bar_baz_qux", r.db_slug
  end

  def test_lowercases_uppercase
    r = call("FEATURE/CamelCaseBranch")
    assert_equal "camelcasebranch", r.slug
    assert_equal "camelcasebranch", r.db_slug
  end

  def test_truncates_to_max_length
    r = call("a" * 100)
    assert_equal 50, r.slug.length
    assert_equal 50, r.db_slug.length
  end

  def test_truncation_does_not_leave_trailing_separator
    r = call("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-x")
    refute r.slug.end_with?("-")
    refute r.db_slug.end_with?("_")
  end

  def test_strips_leading_and_trailing_separators
    r = call("---weird---")
    assert_equal "weird", r.slug
    assert_equal "weird", r.db_slug
  end

  def test_raises_on_empty_branch
    assert_raises(FeatureDeploys::Namer::InvalidBranchName) { call("") }
  end

  def test_raises_on_whitespace_only_branch
    assert_raises(FeatureDeploys::Namer::InvalidBranchName) { call("   ") }
  end

  def test_raises_when_branch_sanitizes_to_empty_string
    assert_raises(FeatureDeploys::Namer::InvalidBranchName) { call("---") }
  end

  def test_dotted_branch_name_dots_become_separators
    r = call("release/2.10.0-rc.1")
    assert_equal "2-10-0-rc-1", r.slug
    assert_equal "b_2_10_0_rc_1", r.db_slug
  end

  def test_custom_prefix_strip
    r = call("ws-456-something", prefix_strip: ["ws-"])
    assert_equal "456-something", r.slug
    assert_equal "b_456_something", r.db_slug
  end

  def test_no_prefix_strip
    r = call("feature/awesome-thing", prefix_strip: [])
    assert_equal "feature-awesome-thing", r.slug
    assert_equal "feature_awesome_thing", r.db_slug
  end

  def test_branch_starting_with_strip_prefix_substring_isnt_stripped
    # "feat/x" should be stripped; "feature-x" shouldn't be touched
    r = call("feature-x", prefix_strip: ["feature/"])
    assert_equal "feature-x", r.slug
  end
end

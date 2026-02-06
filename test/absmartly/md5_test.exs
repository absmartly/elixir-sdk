defmodule ABSmartly.MD5Test do
  use ExUnit.Case, async: true

  alias ABSmartly.Utils

  @md5_test_cases [
    {"", "1B2M2Y8AsgTpgAmY7PhCfg"},
    {" ", "chXunH2dwinSkhpA6JnsXw"},
    {"t", "41jvpIn1gGLxDdcxa2Vkng"},
    {"te", "Vp73JkK-D63XEdakaNaO4Q"},
    {"tes", "KLZi2IO212_Zbk3cXpungA"},
    {"test", "CY9rzUYh03PK3k6DJie09g"},
    {"testy", "K5I_V6RgP8c6sYKz-TVn8g"},
    {"testy1", "8fT8xGipOhPkZ2DncKU-1A"},
    {"testy12", "YqRAtOz000gIu61ErEH18A"},
    {"testy123", "pfV2H07L6WvdqlY0zHuYIw"},
    {"special characters açb↓c", "4PIrO7lKtTxOcj2eMYlG7A"},
    {"The quick brown fox jumps over the lazy dog", "nhB9nTcrtoJr2B01QqQZ1g"},
    {"The quick brown fox jumps over the lazy dog and eats a pie", "iM-8ECRrLUQzixl436y96A"},
    {"Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.", "24m7XOq4f5wPzCqzbBicLA"}
  ]

  describe "hash_unit/1 should match known MD5 hashes" do
    for {input, expected} <- @md5_test_cases do
      @tag_input input
      @tag_expected expected
      test "hashes #{inspect(String.slice(input, 0, 40))} to #{expected}" do
        assert Utils.hash_unit(@tag_input) == @tag_expected
      end
    end
  end
end

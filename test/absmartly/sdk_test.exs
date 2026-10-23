defmodule ABSmartly.SDKTest do
  use ExUnit.Case, async: true

  alias ABSmartly.SDK

  describe "new/1 with keyword list" do
    test "creates SDK with required parameters" do
      assert {:ok, sdk} =
               SDK.new(
                 endpoint: "https://test.absmartly.io/v1",
                 api_key: "test-key",
                 application: "test-app",
                 environment: "test"
               )

      assert sdk.config.endpoint == "https://test.absmartly.io/v1"
      assert sdk.config.api_key == "test-key"
      assert sdk.config.application == "test-app"
      assert sdk.config.environment == "test"
      assert sdk.config.timeout == 3000
      assert sdk.config.retries == 5
    end

    test "creates SDK with custom timeout and retries" do
      assert {:ok, sdk} =
               SDK.new(
                 endpoint: "https://test.absmartly.io/v1",
                 api_key: "test-key",
                 application: "test-app",
                 environment: "test",
                 timeout: 5000,
                 retries: 3
               )

      assert sdk.config.timeout == 5000
      assert sdk.config.retries == 3
    end

    test "returns error when endpoint is missing" do
      assert {:error, error} =
               SDK.new(
                 api_key: "test-key",
                 application: "test-app",
                 environment: "test"
               )

      assert error =~ "Missing required parameters"
      assert error =~ "endpoint"
    end

    test "returns error when api_key is missing" do
      assert {:error, error} =
               SDK.new(
                 endpoint: "https://test.absmartly.io/v1",
                 application: "test-app",
                 environment: "test"
               )

      assert error =~ "Missing required parameters"
      assert error =~ "api_key"
    end

    test "returns error when application is missing" do
      assert {:error, error} =
               SDK.new(
                 endpoint: "https://test.absmartly.io/v1",
                 api_key: "test-key",
                 environment: "test"
               )

      assert error =~ "Missing required parameters"
      assert error =~ "application"
    end

    test "returns error when environment is missing" do
      assert {:error, error} =
               SDK.new(
                 endpoint: "https://test.absmartly.io/v1",
                 api_key: "test-key",
                 application: "test-app"
               )

      assert error =~ "Missing required parameters"
      assert error =~ "environment"
    end

    test "returns error listing all missing parameters" do
      assert {:error, error} = SDK.new([])

      assert error =~ "Missing required parameters"
      assert error =~ "endpoint"
      assert error =~ "api_key"
      assert error =~ "application"
      assert error =~ "environment"
    end
  end

  describe "with_timeout/2" do
    test "updates timeout for SDK instance" do
      result =
        SDK.new(
          endpoint: "https://test.absmartly.io/v1",
          api_key: "test-key",
          application: "test-app",
          environment: "test"
        )
        |> SDK.with_timeout(10_000)

      assert {:ok, sdk} = result
      assert sdk.config.timeout == 10_000
    end

    test "preserves error from new/1" do
      result =
        SDK.new(api_key: "test-key")
        |> SDK.with_timeout(5000)

      assert {:error, _} = result
    end

    test "can be chained" do
      result =
        SDK.new(
          endpoint: "https://test.absmartly.io/v1",
          api_key: "test-key",
          application: "test-app",
          environment: "test"
        )
        |> SDK.with_timeout(8000)
        |> SDK.with_retries(2)

      assert {:ok, sdk} = result
      assert sdk.config.timeout == 8000
      assert sdk.config.retries == 2
    end
  end

  describe "with_retries/2" do
    test "updates retries for SDK instance" do
      result =
        SDK.new(
          endpoint: "https://test.absmartly.io/v1",
          api_key: "test-key",
          application: "test-app",
          environment: "test"
        )
        |> SDK.with_retries(10)

      assert {:ok, sdk} = result
      assert sdk.config.retries == 10
    end

    test "preserves error from new/1" do
      result =
        SDK.new(api_key: "test-key")
        |> SDK.with_retries(3)

      assert {:error, _} = result
    end
  end

  describe "pipe operator usage" do
    test "works with full pipe chain" do
      result =
        SDK.new(
          endpoint: "https://test.absmartly.io/v1",
          api_key: "test-key",
          application: "test-app",
          environment: "test"
        )
        |> SDK.with_timeout(5000)
        |> SDK.with_retries(3)

      assert {:ok, sdk} = result
      assert sdk.config.endpoint == "https://test.absmartly.io/v1"
      assert sdk.config.timeout == 5000
      assert sdk.config.retries == 3
    end

    test "handles error in pipe chain gracefully" do
      result =
        SDK.new(endpoint: "https://test.absmartly.io/v1")
        |> SDK.with_timeout(5000)
        |> SDK.with_retries(3)

      assert {:error, error} = result
      assert error =~ "Missing required parameters"
    end
  end

  describe "idiomatic usage patterns" do
    test "direct usage without unwrapping" do
      {:ok, sdk} =
        SDK.new(
          endpoint: "https://test.absmartly.io/v1",
          api_key: "test-key",
          application: "test-app",
          environment: "test"
        )

      assert sdk.config.application == "test-app"
    end

    test "pattern matching on success" do
      case SDK.new(
             endpoint: "https://test.absmartly.io/v1",
             api_key: "test-key",
             application: "test-app",
             environment: "test"
           ) do
        {:ok, sdk} ->
          assert sdk.config.api_key == "test-key"

        {:error, _} ->
          flunk("Expected success")
      end
    end

    test "pattern matching on failure" do
      case SDK.new(api_key: "test-key") do
        {:ok, _sdk} ->
          flunk("Expected failure")

        {:error, error} ->
          assert error =~ "Missing required parameters"
      end
    end

    test "with statement unwrapping" do
      with {:ok, sdk} <-
             SDK.new(
               endpoint: "https://test.absmartly.io/v1",
               api_key: "test-key",
               application: "test-app",
               environment: "test"
             ) do
        assert sdk.config.environment == "test"
      end
    end
  end

  describe "configuration values" do
    test "applies default timeout of 3000ms" do
      {:ok, sdk} =
        SDK.new(
          endpoint: "https://test.absmartly.io/v1",
          api_key: "test-key",
          application: "test-app",
          environment: "test"
        )

      assert sdk.config.timeout == 3000
    end

    test "applies default retries of 5" do
      {:ok, sdk} =
        SDK.new(
          endpoint: "https://test.absmartly.io/v1",
          api_key: "test-key",
          application: "test-app",
          environment: "test"
        )

      assert sdk.config.retries == 5
    end

    test "accepts timeout override" do
      {:ok, sdk} =
        SDK.new(
          endpoint: "https://test.absmartly.io/v1",
          api_key: "test-key",
          application: "test-app",
          environment: "test",
          timeout: 15_000
        )

      assert sdk.config.timeout == 15_000
    end

    test "accepts retries override" do
      {:ok, sdk} =
        SDK.new(
          endpoint: "https://test.absmartly.io/v1",
          api_key: "test-key",
          application: "test-app",
          environment: "test",
          retries: 1
        )

      assert sdk.config.retries == 1
    end
  end
end

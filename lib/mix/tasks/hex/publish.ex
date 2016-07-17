defmodule Mix.Tasks.Hex.Publish do
  use Mix.Task
  alias Mix.Hex.Utils
  alias Mix.Hex.Build

  @shortdoc "Publishes a new package version"

  @moduledoc """
  Publishes a new version of your package and its documentation.

  `mix hex.publish package`

  If it is a new package being published it will be created and the user
  specified in `username` will be the package owner. Only package owners can
  publish.

  A published version can be amended or reverted with `--revert` up to one hour
  after its publication. Older packages can not be reverted.

  `mix hex.publish docs`

  The documentation will be accessible at `https://hexdocs.pm/my_package/1.0.0`,
  `https://hexdocs.pm/my_package` will always redirect to the latest published
  version.

  Documentation will be generated by running the `mix docs` task. `ex_doc`
  provides this task by default, but any library can be used. Or an alias can be
  used to extend the documentation generation. The expected result of the task
  is the generated documentation located in the `docs/` directory with an
  `index.html` file.

  Note that if you want to publish a new version of your package and its
  documentation in one step, you can use the following shorthand:

  `mix hex.publish`

  ## Command line options

    * `--revert VERSION` - Revert given version
    * `--canonical URL` - Specify the canonical URL for the documentation

  ## Configuration

    * `:app` - Package name (required).

    * `:version` - Package version (required).

    * `:deps` - List of package dependencies (see Dependencies below).

    * `:description` - Short description of the project.

    * `:package` - Hex specific configuration (see Package configuration below).

  ## Dependencies

  Dependencies are defined in mix's dependency format. But instead of using
  `:git` or `:path` as the SCM `:package` is used.

      defp deps do
        [ {:ecto, "~> 0.1.0"},
          {:postgrex, "~> 0.3.0"},
          {:cowboy, github: "extend/cowboy"} ]
      end

  As can be seen Hex package dependencies works alongside git dependencies.
  Important to note is that non-Hex dependencies will not be used during
  dependency resolution and neither will be they listed as dependencies of the
  package.

  ## Package configuration

  Additional metadata of the package can optionally be defined, but it is very
  recommended to do so.

    * `:name` - Set this if the package name is not the same as the application
       name.

    * `:files` - List of files and directories to include in the package,
      can include wildcards. Defaults to `["lib", "priv", "mix.exs", "README*",
      "readme*", "LICENSE*", "license*", "CHANGELOG*", "changelog*", "src"]`.

    * `:maintainers` - List of names and/or emails of maintainers.

    * `:licenses` - List of licenses used by the package.

    * `:links` - Map of links relevant to the package.

    * `:build_tools` - List of build tools that can build the package. Hex will
      try to automatically detect the build tools, it will do this based on the
      files in the package. If a "rebar" or "rebar.config" file is present Hex
      will mark it as able to build with rebar. This detection can be overridden
      by setting this field.
  """

  @switches [revert: :string, progress: :boolean, canonical: :string]

  def run(args) do
    Hex.start
    Hex.Utils.ensure_registry(fetch: false)

    {opts, args, _} = OptionParser.parse(args, switches: @switches)
    auth = Utils.auth_info(Hex.Config.read)

    build = Build.prepare_package!
    version = opts[:revert]

    case args do
      ["package"] ->
        if version, do: revert_package(build, version, auth), else: create_package(build, auth, opts)
      ["docs"] ->
        if version, do: revert_docs(build, version, auth), else: create_docs(auth, opts)
      [] ->
        if version, do: revert(build, version, auth), else: create(build, auth, opts)
      _ ->
        message = """
          invalid arguments, expected one of:
            mix hex.publish
            mix hex.publish package
            mix hex.publish docs
          """
        Mix.raise message
    end
  end

  defp create(build, auth, opts) do
    create_package(build, auth, opts)
    create_docs(auth, opts)
  end

  defp create_package(build, auth, opts) do
    meta = build[:meta]
    exclude_deps = build[:exclude_deps]
    package = build[:package]

    Hex.Shell.info("Publishing #{meta[:name]} #{meta[:version]}")
    Build.print_info(meta, exclude_deps, package[:files])

    print_link_to_coc()

    if Hex.Shell.yes?("Proceed?") do
      progress? = Keyword.get(opts, :progress, true)
      create_release(meta, auth, progress?)
    end
  end

  defp create_docs(auth, opts) do
    Mix.Project.get!
    config  = Mix.Project.config
    name = config[:package][:name] || config[:app]
    version = config[:version]

    try do
      docs_args = ["--canonical", Hex.Utils.hexdocs_url(name)|opts[:canonical]]
      Mix.Task.run("docs", docs_args)
    rescue ex in [Mix.NoTaskError] ->
      stacktrace = System.stacktrace
      Mix.shell.error ~s(The "docs" task is unavailable. Please add {:ex_doc, ">= 0.0.0", only: :dev} ) <>
                      ~s(to your dependencies in your mix.exs. If ex_doc was already added, make sure ) <>
                      ~s(you run the task in the same environment it is configured to)
      reraise ex, stacktrace
    end

    directory = docs_dir()

    unless File.exists?("#{directory}/index.html") do
      Mix.raise "File not found: #{directory}/index.html"
    end

    progress? = Keyword.get(opts, :progress, true)
    tarball = build_tarball(name, version, directory)
    send_tarball(name, version, tarball, auth, progress?)
  end

  defp print_link_to_coc() do
    Hex.Shell.info "Before publishing, please read Hex Code of Conduct: https://hex.pm/policies/codeofconduct"
  end

  defp revert(build, version, auth) do
    revert_package(build, version, auth)
    revert_docs(build, version, auth)
  end

  defp revert_package(build, version, auth) do
    version = Utils.clean_version(version)
    meta = build[:meta]

    case Hex.API.Release.delete(meta[:name], version, auth) do
      {code, _, _} when code in 200..299 ->
        Hex.Shell.info("Reverted #{meta[:name]} #{version}")
      {code, body, _} ->
        Hex.Shell.error("Reverting #{meta[:name]} #{version} failed")
        Hex.Utils.print_error_result(code, body)
    end
  end

  defp revert_docs(build, version, auth) do
    version = Utils.clean_version(version)
    meta = build[:meta]

    case Hex.API.ReleaseDocs.delete(meta[:name], version, auth) do
      {code, _, _} when code in 200..299 ->
        Hex.Shell.info "Reverted docs for #{meta[:name]} #{version}"
      {code, body, _} ->
        Hex.Shell.error "Reverting docs for #{meta[:name]} #{version} failed"
        Hex.Utils.print_error_result(code, body)
    end
  end

  defp build_tarball(name, version, directory) do
    tarball = "#{name}-#{version}-docs.tar.gz"
    files = files(directory)
    :ok = :erl_tar.create(tarball, files, [:compressed])
    data = File.read!(tarball)

    File.rm!(tarball)
    data
  end

  defp send_tarball(name, version, tarball, auth, progress?) do
    progress =
      if progress? do
        Utils.progress(byte_size(tarball))
      else
        Utils.progress(nil)
      end

    case Hex.API.ReleaseDocs.new(name, version, tarball, auth, progress) do
      {code, _, _} when code in 200..299 ->
        Hex.Shell.info ""
        Hex.Shell.info "Published docs for #{name} #{version}"
        Hex.Shell.info "Hosted at #{Hex.Utils.hexdocs_url(name, version)}"
      {code, _, _} when code == 404 ->
        Hex.Shell.info ""
        Hex.Shell.error "Pushing docs for #{name} v#{version} is not possible due to the package not be published"
      {code, body, _} ->
        Hex.Shell.info ""
        Hex.Shell.error "Pushing docs for #{name} v#{version} failed"
        Hex.Utils.print_error_result(code, body)
    end
  end

  defp files(directory) do
    "#{directory}/**"
    |> Path.wildcard
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&{relative_path(&1, directory), File.read!(&1)})
  end

  defp relative_path(file, dir) do
    Path.relative_to(file, dir)
    |> String.to_char_list
  end

  defp docs_dir do
    cond do
      File.exists?("doc") ->
        "doc"
      File.exists?("docs") ->
        "docs"
      true ->
        Mix.raise("Documentation could not be found. Please ensure documentation is in the doc/ or docs/ directory")
    end
  end

  defp create_release(meta, auth, progress?) do
    {tarball, checksum} = Hex.Tar.create(meta, meta[:files])

    progress =
      if progress? do
        Utils.progress(byte_size(tarball))
      else
        Utils.progress(nil)
      end

    case Hex.API.Release.new(meta[:name], tarball, auth, progress) do
      {code, _, _} when code in 200..299 ->
        Hex.Shell.info("\nPublished at #{Hex.Utils.hex_package_url(meta[:name], meta[:version])} (#{String.downcase(checksum)})")
        Hex.Shell.info("Don't forget to upload your documentation with `mix hex.docs`")
      {code, body, _} ->
        Hex.Shell.error("\nPushing #{meta[:name]} #{meta[:version]} failed")
        Hex.Utils.print_error_result(code, body)
    end
  end
end

module DocsFigures

using AlgebraOfVega

const assets = Dict{String,String}()

"""Register build-generated assets; return the iframe embedded by Documenter."""
function figure(spec, name, caption)
    head = join(to_html.(vega_head(source=:inline)))
    plot = to_html(to_node(spec))
    # Mirror the parent theme so AoV can theme axes, tooltips and downloads.
    bridge = """
    <style>
      body { margin: 0; font-size: 15px; }
    </style>
    <script>
      function theme() {
        const style = getComputedStyle(parent.document.body);
        for (const key of ['backgroundColor', 'color', 'fontFamily'])
          document.documentElement.style[key] = style[key];
        document.documentElement.classList.toggle('dark',
          parent.document.documentElement.classList.contains('dark'));
      }
      theme();
      new MutationObserver(theme).observe(parent.document.documentElement,
        {attributes: true, attributeFilter: ['class']});
    </script>
    """
    assets[name * ".html"] = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" *
        bridge * head * "</head><body>" * plot * "</body></html>"
    assets[name * ".json"] = to_json(spec)
    """
    <figure>
      <iframe src="../figures/$name.html" title="$caption"
        style="width:100%;height:320px;border:0" loading="lazy"></iframe>
      <figcaption>$caption <a href="../figures/$name.json">Vega-Lite data and specification</a>.</figcaption>
    </figure>
    """
end

function write_assets(directory)
    mkpath(directory)
    for (name, content) in assets
        write(joinpath(directory, name), content)
    end
end

end

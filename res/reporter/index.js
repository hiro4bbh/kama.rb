function encodeQuery(query) {
  return Object.entries(query).map(function (kv) {
    return kv.map(encodeURIComponent).join('=')
  }).join('&');
}
function encodePathQuery(path, query) {
  var s = path;
  if (query) {
    s += '?'+encodeQuery(query);
  }
  return s;
}
function escapeHTML(text) {
  var elem = document.createElement('div');
  elem.innerText = text;
  return elem.innerHTML;
}
function downloadSVG(svg, filename) {
  var svgblob = 'data:image/xml+svg;utf8,'+encodeURIComponent((new XMLSerializer()).serializeToString(svg));
  var elem = document.createElement('a');
  elem.setAttribute('download', filename);
  elem.setAttribute('href', svgblob);
  elem.click();
}
var defaultLayoutDelta = {dx: 16, dy: 64};
function layoutDendrogram(root, layoutDelta) {
  layoutDelta = layoutDelta || defaultLayoutDelta;
  var dx = layoutDelta.dx, dy = layoutDelta.dy;
  function leafLeft(node) {
    var children;
    while (children = node.children) node = children[0];
    return node;
  }
  function leafRight(node) {
    var children;
    while (children = node.children) node = children[children.length - 1];
    return node;
  }
  // From: https://github.com/d3/d3-hierarchy/blob/3ee15e0a8fe9607ea1094364ca482a03edd5cddb/src/cluster.js#L39-L69
  var previousNode, x = 0;
  // First walk, computing the initial x & y values.
  root.eachAfter(function(node) {
    if (node.children) {
      node.x = node.children.reduce(function(x, c) { return x + c.x; }, 0)/node.children.length;
      node.y = node.data.dist;
    } else {
      node.x = previousNode ? x += 1 : 0;
      node.y = 0;
      previousNode = node;
    }
  });
  // Second walk, normalizing x & y to the desired size.
  var maxy = root.y/1.8;
  root.eachAfter(function(node) {
    node.x = (node.x - root.x)*dx;
    node.y = (maxy - node.y)/maxy*dy;
  });
  root.layout = 'dendrogram';
  return root;
}
function layoutTree(root, layoutDelta) {
  layoutDelta = layoutDelta || defaultLayoutDelta;
  d3.tree().nodeSize([layoutDelta.dx, layoutDelta.dy])(root);
  root.layout = 'tree';
  return root;
}
function updateDendrogramHeightInfo(root, curdist) {
  var s = 'Height Max: '+root.data.dist;
  if (curdist != null) {
    s += ' Split At: '+curdist;
  }
  d3.select('#summary-dendrogram > #height-info').text(s);
}
function drawHeatmap(svg, tagset, groups) {
  svg.html('');
  var width = parseInt(svg.style('width')), height = parseInt(svg.style('height'));
  svg.attr('width', width);
  var margin = {top: 16, right: 8, bottom: 8, left: 128+64};
  var matrix = new Array(tagset.length);
  for (var i = 0; i < tagset.length; i++) {
    var tag = tagset[i];
    matrix[i] = Object.values(groups).map(function(group) { return group[0][tag] || 0; });
  }
  var scaleX = d3.scaleBand().rangeRound([margin.left, width-margin.right]).domain(d3.range(groups.length));
  var scaleY = d3.scaleBand().rangeRound([margin.top, height-margin.bottom]).domain(d3.range(tagset.length));
  svg = svg.append('g').attr('transform', 'translate(0,0)');
  svg.selectAll('.row')
    .data(matrix)
    .enter().append('g')
      .attr("transform", function(d, i) { return 'translate(0,'+scaleY(i)+')'; })
      .selectAll(".cell")
      .data(function(d) { return d; })
      .enter() .append("rect")
        .attr("x", function(d, j) { return scaleX(j); })
        .attr("width", scaleX.bandwidth())
        .attr("height", scaleY.bandwidth())
        .attr("fill", function(d) { return d3.interpolateGreys(d); });
  svg.selectAll('.row')
    .data(matrix)
    .enter().append('text')
      .text(function (d, i) { return tagset[i]; })
      .attr('x', scaleX(0) - 16)
      .attr('y', function(d, i) { return scaleY(i) + scaleY.bandwidth()/2; })
      .style('text-anchor', 'end')
      .style('alignment-baseline', 'central')
      .style('font-family', 'Monaco')
      .style('font-size', '13px');
  svg.selectAll('.column')
    .data(groups)
    .enter().append('text')
      .text(function (d, j) { return j; })
      .attr('x', function(d, j) { return scaleX(j) + scaleX.bandwidth()/2; })
      .attr('y', function(d, i) { return scaleY(0) - 16; })
      .style('text-anchor', 'middle')
      .style('alignment-baseline', 'middle')
      .style('font-family', 'Monaco')
      .style('font-size', '16px')
      .style('fill', function(d, j) { return d3.schemeCategory10[j%10]; });
}
var defaultTreeMargin = {top: 16, right: 0, bottom: 16, left: 80};
function drawTree(svg, root, options) {
  var margin = options.margin || defaultTreeMargin;
  var isStraight = options.isStraight || false;
  var withTextOnPath = options.withTextOnPath || false;
  // Count the number of the leaves.
  var x0 = Infinity, x1 = -x0;
  var y0 = Infinity, y1 = -y0;
  var nleaf = 0;
  root.each(function(d) {
    x0 = Math.min(x0, d.x);
    x1 = Math.max(x1, d.x);
    y0 = Math.min(y0, d.y);
    y1 = Math.max(y1, d.y);
    if (!d.children) {
      nleaf += 1;
    }
  });
  // Create the SVG container.
  svg.html('')
    .attr('height', (x1 - x0) + (margin.top + margin.bottom))
  var g = svg
    .append('g')
    .attr('transform', 'translate('+margin.left+','+(margin.top-x0)+')');
  // Draw the links.
  var link = g.selectAll('.link')
    .data(root.descendants().slice(1))
    .enter().append('path')
      .style('fill', 'none')
      .style('stroke', '#929292')
      .style('stroke-width', '1.5')
      .attr('d', function(d) {
        if (isStraight) {
          return 'M'+d.y+','+d.x + ('L'+d.parent.y+','+d.x) + (' '+d.parent.y+','+d.parent.x) + (' '+ d.parent.y+','+d.parent.x);
        } else {
          return 'M'+d.y+','+d.x + ('C'+(d.y+d.parent.y)/2+','+d.x) + (' '+(d.y+d.parent.y)/2+','+d.parent.x) + (' '+ d.parent.y+','+d.parent.x);
        }
      });
  // Set the nodes.
  var node = g.selectAll('.node')
    .data(root.descendants())
    .enter().append('g')
      .attr('transform', function(d) { return 'translate('+d.y+','+d.x+')'; });
  // Set the nodes' text.
  var text = node
    .append('text')
    .attr('x', '8px')
    .style('alignment-baseline', 'middle')
    .style('text-anchor', 'start')
    .style('font-family', 'Monaco')
    .style('font-size', '12px');
  // Set the nodes' text on the path if needed.
  if (withTextOnPath) {
    var textOnPath = node
      .append('text')
      .attr('x', function(d) { return -4 + (d.parent ? d.parent.y-d.y : 0); })
      .attr('y', function(d) { return 0; })
      .style('alignment-baseline', 'middle')
    .style('text-anchor', 'end')
      .style('font-family', 'Monaco')
      .style('font-size', '12px');
  }
  // Return the elements for customization.
  return {nleaf: nleaf, svg: svg, g: g, node: node, link: link, text: text, textOnPath: textOnPath};
}
var defaultFlatTreeMargin = {top: 16, right: 0, bottom: 16, left: 16};
var defaultFlatTreeSkip = {dx: 16, dy: 16};
function drawFlatTree(svg, root, options) {
  var margin = options.margin || defaultFlatTreeMargin;
  var skip = options.skip || defaultFlatTreeSkip;
  // Count the number of the leaves.
  var x0 = margin.left, x1 = svg.style('width') - margin.right;
  var y0 = margin.top, y1 = margin.top;
  var nleaf = 0;
  root.eachBefore(function(d) {
    d.x = x0 + d.depth*skip.dx;
    d.y = y1;
    y1 += skip.dy;
  });
  // Create the SVG container.
  svg.html('')
    .attr('height', (y1 - y0) + (margin.top + margin.bottom));
  var g = svg
    .append('g');
  // Draw the links.
  var link = g.selectAll('.link')
    .data(root.descendants().slice(1))
    .enter().append('path')
      .style('fill', 'none')
      .style('stroke', '#929292')
      .style('stroke-width', '1.5')
      .attr('d', function(d) {
        return 'M'+d.x+','+d.y + ('L'+d.parent.x+','+d.y) + (' '+d.parent.x+','+d.parent.y) + (' '+ d.parent.x+','+d.parent.y);
      });
  // Set the nodes.
  var node = g.selectAll('.node')
    .data(root.descendants())
    .enter().append('g')
      .attr('transform', function(d) { return 'translate('+d.x+','+d.y+')'; });
  // Set the nodes' text.
  var text = node
    .append('text')
    .attr('x', '8px')
    .style('alignment-baseline', 'middle')
    .style('text-anchor', 'start')
    .style('font-family', 'Monaco')
    .style('font-size', '12px');
  // Return the elements for customization.
  return {svg: svg, g: g, node: node, link: link, text: text};
}
function dumpPage(id) {
  var jsonpath = 'dump.json?id='+id;
  d3.json(jsonpath).then(function(dump) {
    d3.select('#dump-page').style('display', 'block');
    d3.select('#dump-page > h2 > #page-name').text(encodePathQuery(dump.path, dump.query));
    var svg = d3.select('#dump-page > #container > #domtree');
    var tooltip = d3.select('#tooltip');
    // Fix the width.
    svg.attr('width', parseInt(svg.style('width')));
    var width = parseInt(svg.style('width')), height = parseInt(svg.style('height'));
    var domtree = d3.hierarchy(dump.domtree);
    var elems = drawFlatTree(svg, domtree, {});
    // Change the link color.
    elems.link.style('stroke', '#D6D5D5');
    // Set the node circle.
    elems.node
      .append('circle')
      .attr('r', '4px')
      .style('fill', '#929292');
    // Set the node text.
    elems.text.text(function(d) {
        var name = d.data.name, started = false;
        for (var key in d.data.attrs) {
          if (d.data.attrs[key]) {
            if (!started) {
              name += '[';
              started = true;
            }
            name += '@'+key+'='+JSON.stringify(d.data.attrs[key]);
          }
        }
        if (started) {
          name += ']';
        }
        return name;
      })
      .attr('dy', '0px')
      .attr('x', '8px');
    // Set the download link.
    d3.select('#dump-page > #container > #download')
      .on('click', function() {
        downloadSVG(d3.select('#dump-page > #container > #domtree').node(), 'pageDump'+id+'.svg');
      });
    // Set the raw response text.
    d3.select('#dump-page > #container > #rawres').text(dump.rawres);
  });
}
d3.json('online_clusters.json').then(function(data) {
  var svg = d3.select('#heatmap-oclust');
  var tagset = {}, group_centers = [], group_urlsets = [];
  for (var i in data) {
    var center = data[i].center;
    for (var tag in center) {
      tagset[tag] = true;
    }
    group_centers.push([center, 1]);
    group_urlsets.push(data[i].urlset);
  }
  tagset = Object.keys(tagset);
  drawHeatmap(svg, tagset, group_centers);
  // Fix the width.
  svg.attr('width', parseInt(svg.style('width')));
  d3.select('#summary-oclust > #pageset').selectAll('li')
    .data(group_urlsets)
    .enter().append('li')
      .text(function(d) { return d; });
  // Set the download link.
  d3.select('#summary-oclust > #download')
    .on('click', function() {
      downloadSVG(d3.select('#heatmap-oclust').node(), 'heatmap_online_clusters.svg');
    });
});
d3.json('tree.json').then(function(data) {
  var svg = d3.select('#dendrogram');
  // Fix the width.
  svg.attr('width', parseInt(svg.style('width')));
  var root = d3.hierarchy(data.root);
  d3.json('nodes.json').then(function(nodes) {
    layoutDendrogram(root);
    var elems = drawTree(svg, root, {isStraight: true, withTextOnPath: true});
    var height = parseInt(svg.style('height'));
    // Set the leaf text.
    elems.text.filter(function(d) { return !d.children; })
      .text(function(d) {
        if (!d.name) {
          var node = nodes[d.data.name];
          d.name = encodePathQuery(node.infolist[0].path, node.infolist[0].query);
        }
        return '\u25a0 '+d.name;
      })
      .on('click', function(d) {
        d3.select('#summary-pageset').style('display', 'block');
        d3.select('#summary-pageset > h2 > #pageset-name').text(d.name);
        d3.select('#summary-pageset > #container > #pagelist').html(nodes[d.data.name].infolist.map(function(info) {
          return '<a href="javascript:dumpPage('+info.id+')">'+escapeHTML(encodePathQuery(info.path, info.query))+'</a>';
        }).join(' '));
        d3.select('#summary-pageset > #container > #histogram').text(JSON.stringify(nodes[d.data.name].hist));
      });
    var currentTarget;
    // Set the vertical line for the splitter.
    var vline = elems.g.append('line')
      .attr('y1', -height)
      .attr('y2', +height)
      .style('display', 'none')
      .style('stroke', '#000000')
      .style('stroke-width', 1.5);
    // Set the selectors of each non-terminal node.
    elems.node.filter(function(d) { return d.children; })
      .append('circle')
      .attr('r', '4px')
      .style('fill', '#929292')
      .on('click', function(d) {
        var target = d3.select(this);
        target.style('fill', '#000000');
        if (currentTarget && (currentTarget != target)) {
          currentTarget.style('fill', '#929292');
        }
        vline.attr('x1', d.y).attr('x2', d.y).style('display', 'block');
        updateDendrogramHeightInfo(root, d.data.dist);
        var groups = [], thresh = d.y;
        root.eachBefore(function(d) {
          if ((d.parent && d.parent.y <= thresh) || d.y <= thresh) {
            d.gid = groups.length;
            groups.push([d.data.vec, 1]);
            d.groupRoot = true;
          } else {
            d.gid = d.parent.gid;
            groups[d.parent.gid][1] += 1;
            d.groupRoot = false;
          }
        });
        elems.text.style('fill', function(d) {
          return d3.schemeCategory10[d.gid%10];
        });
        ndigit = Math.ceil(Math.log10(groups.length)+0.1);
        elems.textOnPath
          .style('fill', function(d) {
            return d3.schemeCategory10[d.gid%10];
          })
          .text(function(d) {
            return d.groupRoot ? d.gid : '';
          });
        elems.link.style('stroke', function(d) {
          return d3.schemeCategory10[d.gid%10];
        });
        d3.select('#summary-clusters').style('display', 'block');
        var tagset = {};
        groups.forEach(function(group) {
          Object.keys(group[0]).forEach(function(tag) { tagset[tag] = true; });
        });
        tagset = Object.keys(tagset);
        console.log(tagset);
        console.log(groups);
        drawHeatmap(d3.select('#summary-clusters > #heatmap'), tagset, groups);
        d3.select('#summary-clusters > #download')
          .on('click', function() {
            downloadSVG(d3.select('#summary-clusters > #heatmap').node(), 'groupsHeatmap.svg');
          });
        currentTarget = target;
      });
    // Set the download link.
    d3.select('#summary-dendrogram > #download')
      .on('click', function() {
        downloadSVG(d3.select('#dendrogram').node(), 'dendrogram.svg');
      });
    // Set the summary information.
    d3.select('#summary-dendrogram > #pageset-info').text(elems.nleaf+' page(s) clustered (hierarchical: '+data.hclust_method+', similarity: '+data.hclust_sim+', embedding: '+data.embed_method+', black tags: '+data.blacktag_pattern+')');
    updateDendrogramHeightInfo(root, null);
  });
});

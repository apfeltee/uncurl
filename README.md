
uncurl is not curl. but *almost*.

I wrote it to grok out the most important info about a URL right away:

  + if it redirects, track and follow redirects
  + show HTTP headers
  + if html, also print `<title>` and ye olde nasty `<meta>` trickery (like meta-refresh redirects).

It's fairly easy to extend, and easy to use.  

Just do `./main.rb http://some.url/foo`, or just a host, `./main.rb some.url`.  
The latter turns the hostname into a url, a la `http://some.url/`, even if the argument is `some.url/foo`, et cetera.

In short, it automates what I usually do first when encountering a strange URL. Only, with less typing.

-----

Unless stated otherwise, the files in this repository are licensed under the terms of the MIT/X11 license.  


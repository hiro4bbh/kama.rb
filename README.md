# kama.rb - A Black-Box Testing Framework for Web Apps
![kama.rb logo](https://rawgit.com/hiro4bbh/kama.rb/master/logo.svg)

Copyright 2018- Tatsuhiro Aoshima (hiro4bbh@gmail.com).

## Introduction
kama.rb is a black-box testing framework for Web apps.
It currently supports the __Cross Site Scripting__ (XSS) and __SQL Injection__ (SQLI) vulnerabilities (vulns).
Any prior knowledge about the target system internals is not assumed for testing (__black-box testing__).

## Framework Overview
First, kama.rb traverse the links in the pages, and apply the online clustering of the pages (__taint analysis__).
Unlike the previous works __(Djuric 2013, Duchene+ 2014)__, our method requires only one hyper-parameter: the size of the cluster.
This can be tuned easily, as the user starts the larger value (for example, 0.5), then shrink it while unique vulns are found.
kama.rb uses the DOM tree structures for creating the __Full-BOT vectors__ (Bag-Of-Tags vectors with FULL path),
  hence our method can identify the features provided by Web app more robustly than the previous works using the dissimilarities between HTML strings do.
The dissimilarity between the two Full-BOT vectors is the one based on Jaccard (recommended) or cosine similarity,
  and the dissimilarity between the given Full-BOT vector and the cluster is the minimum one against each vector in the cluster.

In the taint analysis, in order to detect XSS vulns, kama.rb fill the input fields with the uniquely generated __marker__ (14-length random capital alphabet string).
If a marker is detected in another page, then it implies that there would be a XSS vuln.
When each input/reflection pair is detected, then kama.rb tries the __only six__ attack patterns for detecting any known XSS vulns.
Unlike the previous work __(Duchene+ 2014)__, there is no need to maintain somewhat complex and obscure genetic algorithms.

For SQLI vulns, kama.rb sends the __only one__ attack pattern.
If the returned result are different from the normal result, which can be detected with the difference of each Full-BOT vector, it tries at most 25 times for detecting the reflection of the extracted database content.
Unlike the previous work __(Djuric 2013)__, there is no need to try the multiple patterns.
Furthermore kama.rb does not assume any SQL error message pattern, so it is more robust and easy to support other database code injection vulns.

## Experiments
We confirmed the XSS vuln scanner performance of kama.rb with Webseclab __(Yahoo Inc. 2018)__.
It can detect all nine XSS exploitable vulns correctly, as ignoring the three unexploitable patterns correctly.

kama.rb can detect the 13 XSS vulns in Gruyere __(Leban+ 2017)__, which is three times more than four vulns detected by the previous work __(Duchene+ 2014)__.
We used the same criterion that the vulns are uniquely determined with the pair of the input and reflection locations (path and query parameters).
However, this is somewhat vague, because there is an example such that the two different edit pages have the different query parameters.
Hence, we classify the vulns by the features provided by Web apps (the two different edit pages are classfied as same one).

The previous works __(Djuric 2013, Duchene+ 2014)__ uses the string similarity measures for classifying the pages, so these methods would be confused by the user contents containing dates, locations or messages.
We developed an intentionally vuln Web calendar app __Weakdays__ (`./example/weakdays/server.rb`) for showing the those method limitations.
kama.rb found 16 XSS and 16 SQLI vulns in Weakdays.
Two of the detected 16 SQLI vulns were false-positive (meaning that those are not exploitable), however this is caused by the assumption violation that:
  (1) kama.rb ignores the error message contents and
  (2) the given query parameter template will not cause any error.
We confirmed that we can fix all detected vulns (`./example/weakdays/server_stronger.rb`).

## WARNING
I WILL NOT RELEASE the internals and codes of the taint analyzer (`./bin/fuzzer.rb`) and the attackers (`./lib/exploit/*`), due to the compliance.
I will distribute these to the users satisfying the following conditions:
  (1) I know the users,
  (2) I can trust that the users can treat these correctly.

Please DO NOT USE Weakdays in production environments, because it has many vulns intentionally.

## SPECIAL THANKS
- みふねたかし at いらすとや ([https://www.irasutoya.com/](https://www.irasutoya.com/)): `example/weakdays/res/icon*.png`

## References
- __(Djuric 2013)__ Djuric, Z. 2013. "A Black-Box Testing Tool for Detecting SQL Injection Vulnerabilities." _The Second International Conference on Informatics and Applications_, IEEE.
- __(Duchene+ 2014)__ Duchene, F., et al. 2014. "KameleonFuzz: Evolutionary Fuzzing for Black-Box XSS Detection." _Proceedings of the 4th Conference on Data and Application Security and Privacy_, ACM.
- __(Leban+ 2017)__ Leban, B., M. Bendre and P. Tabriz. 2017. "Web Application Exploits and Defenses." [https://google-gruyere.appspot.com/](https://google-gruyere.appspot.com/).
- __(Yahoo Inc. 2018)__ Yahoo Inc. 2018. "Webseclab - set of web security test cases and a toolkit to construct new ones." [https://github.com/yahoo/webseclab](https://github.com/yahoo/webseclab).

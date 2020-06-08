import React from 'react';
import logo from './logo.svg';
import './App.css';

var RestApiHost = 'localhost:4567'

function PokerCards(props) {
  const suitMap = { S: '♠', H: '♥', D: '♦', C: '♣' };
  return (
    <span>
      {props.cards.map((c, i) =>
        <span key={i} className={`suit-${c[0]}`}>{`${suitMap[c[0]]}${c.substring(1)}`}</span>
      )}
    </span>
  );
}

class PokerTable extends React.Component {
  // props:
  // credentials={this.state.credentials} username={this.state.username} tablename={this.state.tablename}
  constructor(props) {
    super(props);

    this.state = {
      clientId: Math.random().toString(36).substr(2, 5)
    };
    this.state = Object.assign(this.state, this.getInitState());
    this.tableClosed = false;
    // this.pollEvents = this.pollEvents.bind(this)
    this.handleActionButton = this.handleActionButton.bind(this);
    this.handleAmountChange = this.handleAmountChange.bind(this);

  }

  getInitState() {
    return {
      gamestate: null,
      playercards: {},
      whosnext: null,
      error: null,
      raiseAmount: 20
    };
  }

  getHeaders() {
    return {headers: {'X-Username': this.props.credentials}};
  }

  pollEvents() {
    // console.log("pollEvents called, numberOfFetches: " + this.state.numberOfFetches);
    fetch(`http://${RestApiHost}/api/poll-events?channel=table-${this.props.tablename},player-${this.props.username}:${this.props.tablename}&dontclose&id=${this.state.clientId}`,
      this.getHeaders()
    ).then(response => {
      // console.log("pollEvents succeeded, numberOfFetches: " + this.state.numberOfFetches);
      if (response.ok) {
        var buffer = "";
        var reader = response.body.getReader();

        var processEvent = resp => {
          console.log(`Event with type ${resp.evt.type} received`, resp);
          if (resp.evt.type == "GameStateEvent") {
            this.setState({ "gamestate": resp.evt.event });
          } else if (resp.evt.type == "WhosNextEvent") {
            this.setState({ "whosnext": resp.evt.event });
          } else if (resp.evt.type == "PlayerCardsEvent") {
            this.setState((state) => {
              var newobj = Object.assign({}, state.playercards);
              newobj[resp.evt.event.player] = resp.evt.event;
              return {"playercards": newobj};
            });
          }
        }

        function findNextEvent({done, value}) {
          var chunk = new TextDecoder("utf-8").decode(value);
          var sep = "\n{\"separator\":\"cb935688-891a-45d1-9692-0275ab14be96\"}\n";
          if (done) {
            console.log("pollEvents got end-of-stream");
            return;
          }
          // console.log("got chunk: ", chunk);
          buffer += chunk;
          var ind;
          while ((ind = buffer.indexOf(sep)) >= 0) {
            var json = buffer.substring(0, ind);
            // console.log("json found: ", json);
            buffer = buffer.substring(ind + sep.length);
            // console.log("new buffer:", buffer);

            processEvent(JSON.parse(json));
          }
          return reader.read().then(findNextEvent);
        }

        return reader.read().then(findNextEvent);
        // return response.json();
      } else {
        throw new Error(`State error: ${response.status} ${response.statusText} - ${response.text()}`);
      }
    }).catch(error => {
      console.error(`Fetch error: ${error}`);
      this.setState((state) => ({ gamestate: null, error: error }));
    });
  }

  async componentDidMount() {
    console.log("PokerTable.componentDidMount()");
    this.setState(this.getInitState());
    // cancel any /poll-events request currently running
    await fetch(`http://${RestApiHost}/api/cancel-poll?id=${this.state.clientId}`, this.getHeaders() );
    this.pollEvents();
    fetch(`http://${RestApiHost}/api/tables/${this.props.tablename}/resend-events`, this.getHeaders() );
  }

  componentDidUpdate(prev) {
    console.log("PokerTable.componentDidUpdate()");
    if (prev.credentials != this.props.credentials || prev.tablename != this.props.tablename) {
      this.componentDidMount();
    }
  }

  async handleActionButton(event, action) {
    var payload = {
      what: action,
    };
    if (['raise', 'bet'].includes(action)) {
      payload["raise_amount"] = this.state.raiseAmount;
    }
    // TODO block UI until ready
    await fetch(`http://${RestApiHost}/api/tables/${this.props.tablename}/action`, Object.assign({
        method: "POST",
        body: JSON.stringify(payload)
      }, this.getHeaders())
    );
  }

  handleAmountChange(event) {
    this.setState({raiseAmount: event.target.value});
  }

  render() {
    console.log("state:", this.state);
    if (!this.state.gamestate || !this.state.playercards) {
      return (<div>No active game...</div>);
    }
    if (!this.props.credentials) {
      return (<div>Please log in</div>);
    }
    if (!this.state.gamestate.pigs.find(p => p.name == this.props.username)) {
      return (<div>Not joined to the table</div>);
    }
    const suitMap = { S: '♠', H: '♥', D: '♦', C: '♣' };
    return (
      <div>
        <h3>Gamestate:</h3>
        Players:
        {this.state.gamestate.pigs.map((pig, i) => {
          return (
            <div key={pig.name}>
              <h4 key={pig.name}>Player {pig.name}{i==this.state.gamestate.button && " (button)"
                }{i==this.state.gamestate.waiting_for && !this.state.gamestate.finished && " (in turn)"
                }{pig.folded && " (folded)"
                }{this.state.gamestate.winners.includes(pig.name) && " (winner)"
                }</h4>
              {this.state.playercards[pig.name] &&
                <div>
                  Cards: <PokerCards cards={this.state.playercards[pig.name].cards}/> ({this.state.playercards[pig.name].rank})
                </div>
              }
              <div>Money: {pig.money}</div>
              <div>Bet in this round: {pig.money_in_round}</div>
              {!this.state.gamestate.finished && this.state.whosnext && this.props.username == pig.name && this.props.username == this.state.whosnext.player &&
                <div>
                Actions:
                {this.state.whosnext.actions.map((act) => {
                  var needsraise = ['raise', 'bet'].includes(act);
                    return <span key={act}>
                      { needsraise &&
                        <input type="text" pattern="[0-9]+" onInput={this.handleAmountChange} value={this.state.raiseAmount}/>
                      }
                      <button onClick={(e) => this.handleActionButton(e, act)} className="actionButton">{act
                        }{needsraise && ` $${this.state.raiseAmount}`
                        }{act=="call" && ` $${this.state.whosnext.call_amount}`}
                      </button>
                    </span>;
                })}
                </div>
              }
              <div>
              </div>

              {/* "name": "p1",
      "starting_money": 1000,
      "money": 980,
      "last_action": null,
      "money_in_round": 0,
      "folded": false               */}
            </div>
          )
        })}
        <h3>Board</h3>
        <div>
          Community cards: <PokerCards cards={this.state.gamestate.community_cards}/>
        </div>
        <div>
          Money in pot: {this.state.gamestate.money_in_pot}
        </div>
        <pre>
          {JSON.stringify(this.state.gamestate, null, 2)}
        </pre>
      </div>
    );
  }

}

class LoginForm extends React.Component {
  constructor(props) {
    super(props);
    this.state = { username: this.props.username, pass: this.props.password, tablename: this.props.tablename };
    this.handleUsernameChange = this.handleUsernameChange.bind(this);
    this.handlePasswordChange = this.handlePasswordChange.bind(this);
    this.handleTableNameChange = this.handleTableNameChange.bind(this);
    this.handleSubmit = this.handleSubmit.bind(this);
  }

  handleUsernameChange(event) {
    this.setState({username: event.target.value});
  }
  handlePasswordChange(event) {
    this.setState({pass: event.target.value});
  }
  handleTableNameChange(event) {
    this.setState({tablename: event.target.value});
  }

  handleSubmit(event) {
    event.preventDefault();
    console.log("Logging in user " + this.state.username + ", joining to table " + this.state.tablename);
    this.props.onLogin(this.state.username, this.state.pass, this.state.tablename);
  }

  render() {
    return (
      <form onSubmit={this.handleSubmit}>
        <label>
          Player:
          <input type="text" value={this.state.username} onChange={this.handleUsernameChange} />
        </label>
        <br/>
        <label>
          Password:
          <input type="password" value={this.state.pass} onChange={this.handlePasswordChange} />
        </label>
        <label>
          Table:
          <input type="text" value={this.state.tablename} onChange={this.handleTableNameChange} />
        </label>
        <input type="submit" value="Enter" />
      </form>
    );
  }
}

class App extends React.Component {
  constructor(props) {
    super(props);
    console.log("sessionStorage: ", sessionStorage);
    this.state = {
      username: sessionStorage.getItem('friendspoker.username') || '',
      password: sessionStorage.getItem('friendspoker.password') || '',
      tablename: sessionStorage.getItem('friendspoker.tablename') || '',
      credentials: sessionStorage.getItem('friendspoker.credentials') || '',
    };
    // if (this.state.credentials && this.state.credentials.split(":")[1]) {
    //   this.state.password = this.state.credentials.split(":")[1];
    // }
    this.onLogin = this.onLogin.bind(this);
    // this.handleTableNameChange = this.handleTableNameChange.bind(this);
  }

  updateState(h) {
    for (let key of ['username', 'password', 'tablename', 'credentials']) {
      if (h[key]) {
        sessionStorage.setItem(`friendspoker.${key}`, h[key]);
      }
    }
    this.setState(h);
  }

  onLogin(name, pass, tablename) {
    console.log(`onLogin(${name}, ${pass}) called`);
    this.updateState({ "username": name, password: pass, tablename: tablename, "credentials": `${name}:${pass}` });
  }

  render() {
    return (
      <div>
        <LoginForm username={this.state.username} password={this.state.password} tablename={this.state.tablename} onLogin={this.onLogin}/>

        <div className="App">
          <PokerTable credentials={this.state.credentials} username={this.state.username} tablename={this.state.tablename}/>
        </div>
      </div>
    );
  }
}

export default App;
